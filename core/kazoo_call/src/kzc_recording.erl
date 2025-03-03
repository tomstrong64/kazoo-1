%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2022, 2600Hz
%%% @doc Handles starting/stopping a call recording.
%%%
%%% Callflow action Data:
%%% ```
%%% "data":{
%%%   "action":["start","stop"] // one of these
%%%   ,"time_limit":600 // in seconds, how long to record the call
%%%   ,"format":["mp3","wav"] // what format to store the recording in
%%%   ,"url":"http://server.com/path/to/dump/file" // what URL to PUT the file to
%%%   ,"record_on_answer": boolean() // whether to delay the start of the recording
%%% }
%%% '''
%%%
%%% @author James Aimonetti
%%% @author Sponsored by Velvetech LLC, Implemented by SIPLABS LLC
%%% @end
%%%-----------------------------------------------------------------------------
-module(kzc_recording).

-behaviour(gen_listener).

-export([start_link/2
        ,handle_call_event/2

        ,get_timelimit/1
        ,get_format/1
        ,get_media_name/2
        ,get_response_media/1
        ,should_store_recording/2
        ]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-include_lib("kazoo_stdlib/include/kz_types.hrl").

-define(SERVER, ?MODULE).
-define(RECORDING_TIMER_EXPIRED, 'recording_timer_expired').
-define(RECORDING_STOP_TIMER_EXPIRED, 'recording_stop_timer_expired').
-define(RECORDING_STOP_TIMER_EXPIRED_MS, 30 * ?MILLISECONDS_IN_SECOND).

-type media_directory() :: file:filename_all().
-type media_name() :: file:filename_all().
-type media() :: {media_directory() | 'undefined', media_name()}.

-type store_url() :: 'false' |
                     {'true', 'local'} |
                     {'true', 'other', kz_term:ne_binary()}.

-record(state, {url                       :: kz_term:api_ne_binary()
               ,format                    :: kz_term:api_ne_binary()
               ,sample_rate               :: kz_term:api_integer()
               ,media                     :: media() | 'undefined'
               ,doc_modb                  :: kz_term:api_ne_binary()
               ,doc_id                    :: kz_term:api_ne_binary()
               ,cdr_id                    :: kz_term:api_ne_binary()
               ,interaction_id            :: kz_term:api_ne_binary()
               ,call                      :: kapps_call:call() | 'undefined'
               ,record_on_answer          :: kz_term:api_boolean()
               ,record_on_bridge          :: kz_term:api_boolean()
               ,should_store              :: store_url() | 'undefined'
               ,time_limit                :: kz_term:api_pos_integer()
               ,timer_ref                 :: kz_term:api_reference()
               ,record_min_sec            :: kz_term:api_pos_integer()
               ,store_attempted = 'false' :: boolean()
               ,is_recording = 'false'    :: boolean()
               ,stop_received = 'false'   :: boolean()
               ,retries = 0               :: non_neg_integer()
               ,verb = <<"put">>          :: kz_term:ne_binary()
               ,account_id                :: kz_term:api_ne_binary()
               ,event = 'undefined'       :: kz_call_event:doc() | 'undefined'
               ,origin                    :: kz_term:api_ne_binary()
               }).
-type state() :: #state{}.

-define(STORAGE_RETRY_TIMES(AccountId)
       ,kz_media_config:storage_retry_times(AccountId)
       ).

%% By convention, we put the options here in macros, but not required.
-define(BINDINGS(CallId), [{'call', [{'callid', CallId}
                                    ,{'restrict_to', ['CHANNEL_ANSWER'
                                                     ,'CHANNEL_BRIDGE'
                                                     ,'RECORD_START'
                                                     ,'RECORD_STOP'
                                                     ,'CHANNEL_REPLACED'
                                                     ,'CHANNEL_TRANSFEROR'
                                                     ,'CHANNEL_DESTROY'
                                                     ]}
                                    ]}
                          ,{'self', []}
                          ]
       ).
-define(CALL_BINDING(CallId), {'call', [{'callid', CallId}
                                       ,{'restrict_to', ['RECORD_STOP'
                                                        ,'CHANNEL_REPLACED'
                                                        ,'CHANNEL_TRANSFEROR'
                                                        ,'CHANNEL_DESTROY'
                                                        ]
                                        }
                                       ]
                              }
       ).
-define(RESPONDERS, [{{?MODULE, 'handle_call_event'}
                     ,[{<<"*">>, <<"*">>}]
                     }
                    ]
       ).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).
-define(MAX_RECORDING_LIMIT, kz_media_util:max_recording_time_limit()).
-define(CHECK_CHANNEL_STATUS_TIMEOUT, 5 * ?MILLISECONDS_IN_SECOND).
-define(RECORDING_ID_KEY, <<"media_name">>).

-spec start_link(kapps_call:call(), kz_json:object()) -> kz_types:startlink_ret().
start_link(Call, Data) ->
    gen_listener:start_link(?SERVER
                           ,[{'bindings', ?BINDINGS(kapps_call:call_id(Call))}
                            ,{'responders', ?RESPONDERS}
                            ,{'queue_name', ?QUEUE_NAME}       % optional to include
                            ,{'queue_options', ?QUEUE_OPTIONS} % optional to include
                            ,{'consume_options', ?CONSUME_OPTIONS} % optional to include
                            ]
                           ,[Call, Data]
                           ).

-spec get_response_media(kz_json:object()) -> media().
get_response_media(JObj) ->
    Filename = kz_call_event:application_response(JObj),
    {filename:dirname(Filename), filename:basename(Filename)}.

-spec handle_call_event(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_call_event(JObj, Props) ->
    kz_util:put_callid(JObj),
    Pid = props:get_value('server', Props),
    case kz_util:get_event_type(JObj) of
        {<<"call_event">>, <<"CHANNEL_TRANSFEROR">>} ->
            gen_listener:add_binding(Pid, ?CALL_BINDING(kz_call_event:other_leg_call_id(JObj)));
        {<<"call_event">>, <<"CHANNEL_BRIDGE">>} ->
            gen_listener:cast(Pid, 'maybe_start_recording_on_bridge');
        {<<"call_event">>, <<"CHANNEL_ANSWER">>} ->
            gen_listener:cast(Pid, 'maybe_start_recording_on_answer');
        {<<"call_event">>, <<"CHANNEL_REPLACED">>} ->
            gen_listener:add_binding(Pid, ?CALL_BINDING(kz_call_event:replaced_by(JObj)));
        {<<"call_event">>, <<"RECORD_START">>} ->
            gen_listener:cast(Pid, {'record_start', get_response_media(JObj)});
        {<<"call_event">>, <<"RECORD_STOP">>} ->
            Media = get_response_media(JObj),
            FreeSWITCHNode = kz_call_event:switch_nodename(JObj),
            gen_listener:cast(Pid, {'record_stop', Media, FreeSWITCHNode, JObj});
        {<<"call_event">>, <<"CHANNEL_DESTROY">>} ->
            gen_listener:cast(Pid, 'channel_destroyed');
        {<<"call_event">>, <<"channel_status_resp">>} ->
            handle_channel_status_resp(JObj, Pid);
        {_Cat, _Evt} -> 'ok'
    end.

-spec init([kapps_call:call() | kz_json:object()]) -> {'ok', state()}.
init([Call, Data]) ->
    init(Call, Data).

-spec init(kapps_call:call(), kz_json:object()) -> {'ok', state()}.
init(Call, Data) ->
    kapps_call:put_callid(Call),
    lager:info("starting event listener for record_call"),

    gen_listener:cast(self(), {'initialize', Call, Data}),

    {'ok', #state{}}.

-spec initialize_state(kapps_call:call(), kz_json:object()) -> state().
initialize_state(Call, Data) ->
    Format = get_format(kz_json:get_ne_binary_value(<<"format">>, Data)),
    TimeLimit = get_timelimit(kz_json:get_integer_value(<<"time_limit">>, Data)),
    RecordOnAnswer = kz_json:is_true(<<"record_on_answer">>, Data, 'false'),
    RecordOnBridge = kz_json:is_true(<<"record_on_bridge">>, Data, 'false'),
    SampleRate = kz_json:get_integer_value(<<"record_sample_rate">>, Data),
    DefaultRecordMinSec = kz_media_config:record_min_sec(),
    RecordMinSec = kz_json:get_integer_value(<<"record_min_sec">>, Data, DefaultRecordMinSec),
    AccountId = kapps_call:account_id(Call),
    {Year, Month, _} = erlang:date(),
    AccountMODb = kz_util:format_account_modb(kazoo_modb:get_modb(AccountId, Year, Month), 'encoded'),
    CallId = kapps_call:call_id(Call),
    CdrId = ?MATCH_MODB_PREFIX(kz_term:to_binary(Year), kz_date:pad_month(Month), CallId),
    RecordingId = kz_binary:rand_hex(16),
    DocId = ?MATCH_MODB_PREFIX(kz_term:to_binary(Year), kz_date:pad_month(Month), RecordingId),
    InteractionId = kapps_call:custom_channel_var(<<?CALL_INTERACTION_ID>>, Call),
    DefaultMediaName = get_media_name(kz_binary:rand_hex(16), Format),
    MediaName = kz_json:get_ne_binary_value(?RECORDING_ID_KEY, Data, DefaultMediaName),
    Url = kz_json:get_ne_binary_value(<<"url">>, Data),
    ShouldStore = should_store_recording(AccountId, Url),
    Verb = kz_json:get_ne_binary_value(<<"method">>, Data, <<"put">>),
    Request = kapps_call:request_user(Call),
    Origin = kz_json:get_ne_binary_value(<<"origin">>, Data, <<"untracked : ", Request/binary>>),

    #state{url=Url
          ,format=Format
          ,media={'undefined',MediaName}
          ,doc_id=DocId
          ,doc_modb=AccountMODb
          ,cdr_id=CdrId
          ,interaction_id=InteractionId
          ,call=Call
          ,time_limit=TimeLimit
          ,record_on_answer=RecordOnAnswer
          ,record_on_bridge=RecordOnBridge
          ,should_store=ShouldStore
          ,sample_rate = SampleRate
          ,record_min_sec = RecordMinSec
          ,retries = ?STORAGE_RETRY_TIMES(AccountId)
          ,verb = Verb
          ,account_id = AccountId
          ,origin = Origin
          }.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'initialize', Call, Data}, _State) ->
    {'noreply', initialize_state(Call, Data)};

handle_cast({'record_start', {_, Media}}, #state{media={_, Media}
                                                ,is_recording='true'
                                                }=State) ->
    lager:debug("record start received but we're already recording"),
    {'noreply', State};
handle_cast({'record_start', {_, Media}}, #state{media={_, Media}
                                                ,timer_ref=TRef
                                                }=State) ->
    lager:debug("record start received for ~s", [Media]),
    maybe_stop_timer(TRef),
    {'noreply', State#state{is_recording='true'}};
handle_cast({'record_start', _}, #state{timer_ref=TRef}=State) ->
    maybe_stop_timer(TRef),
    {'noreply', State};

handle_cast('stop_recording', #state{media={_, MediaName}
                                    ,is_recording='true'
                                    ,call=Call
                                    ,timer_ref=TRef
                                    }=State) ->
    _ = kapps_call_command:record_call([{<<"Media-Name">>, MediaName}], <<"stop">>, Call),
    maybe_stop_timer(TRef),
    lager:info("sent command to stop recording, waiting for record stop"),
    {'noreply', State#state{timer_ref=start_recording_stop_timer()}};
handle_cast('stop_recording', #state{is_recording='false'}=State) ->
    lager:debug("received stop recording and we're not recording, exiting"),
    {'stop', 'normal', State};

handle_cast('channel_destroyed', #state{is_recording='true'
                                       ,stop_received='false'
                                       ,timer_ref=TRef
                                       }=State) ->
    lager:info("channel was destroyed, waiting on RECORD_STOP or shutting down"),
    maybe_stop_timer(TRef),
    {'noreply', State#state{timer_ref=start_recording_stop_timer()}};
handle_cast('channel_destroyed', State) ->
    lager:debug("ignoring channel destroyed while storing"),
    {'noreply', State};

handle_cast({'record_stop', {_, MediaName}=Media, FS, EventJObj},
            #state{media={_, MediaName}
                  ,is_recording='true'
                  ,stop_received='false'
                  ,call=Call
                  ,timer_ref=TRef
                  }=State) ->
    lager:debug("received record_stop, storing recording ~s", [MediaName]),
    Call1 = kapps_call:kvs_store(<<"FreeSwitch-Node">>, FS, Call),
    Call2 = kapps_call:set_switch_nodename(FS, Call1),
    gen_server:cast(self(), 'store_recording'),
    maybe_stop_timer(TRef),
    {'noreply', State#state{media=Media
                           ,call=Call2
                           ,stop_received='true'
                           ,event=EventJObj
                           ,timer_ref='undefined'
                           }};
handle_cast({'record_stop', {_, MediaName}, _FS, _JObj}, #state{media={_, MediaName}
                                                               ,is_recording='false'
                                                               ,stop_received='false'
                                                               ,timer_ref=TRef
                                                               }=State) ->
    lager:debug("received record_stop but we're not recording, exiting"),
    maybe_stop_timer(TRef),
    {'stop', 'normal', State};
handle_cast({'record_stop', _Media, _FS, _JObj}, State) ->
    {'noreply', State};

handle_cast('maybe_start_recording_on_bridge', #state{is_recording='true'}=State) ->
    {'noreply', State};
handle_cast('maybe_start_recording_on_bridge', #state{is_recording='false'
                                                     ,record_on_bridge='true'
                                                     ,call=Call
                                                     ,media={_, MediaName}
                                                     ,time_limit=TimeLimit
                                                     ,sample_rate = SampleRate
                                                     ,record_min_sec = RecordMinSec
                                                     ,doc_id=Id
                                                     }=State) ->
    start_recording(Call, MediaName, TimeLimit, Id, SampleRate, RecordMinSec),
    {'noreply', State};
handle_cast('maybe_start_recording_on_answer', #state{is_recording='true'}=State) ->
    {'noreply', State};
handle_cast('maybe_start_recording_on_answer', #state{is_recording='false'
                                                     ,record_on_answer='true'
                                                     ,call=Call
                                                     ,media={_, MediaName}
                                                     ,time_limit=TimeLimit
                                                     ,sample_rate = SampleRate
                                                     ,record_min_sec = RecordMinSec
                                                     ,doc_id=Id
                                                     }=State) ->
    start_recording(Call, MediaName, TimeLimit, Id, SampleRate, RecordMinSec),
    {'noreply', State};
handle_cast('recording_started', #state{should_store='false'}=State) ->
    lager:debug("recording started and we are not storing, exiting"),
    {'stop', 'normal', State};
handle_cast('recording_started', #state{time_limit=TimeLimit}=State) ->
    {'noreply', State#state{timer_ref=start_recording_timer(TimeLimit)}};
handle_cast('store_recording', #state{should_store=Store
                                     ,is_recording='true'
                                     ,store_attempted='false'
                                     }=State) ->
    lager:debug("attempting to save recording"),
    save_recording(State, Store),
    {'noreply', State#state{store_attempted='true'
                           ,is_recording='false'
                           }};
handle_cast('store_recording', #state{store_attempted='true'}=State) ->
    {'noreply', State};
handle_cast('store_recording', #state{is_recording='false'}=State) ->
    lager:debug("store_recording event but we're not recording, exiting"),
    {'stop', 'normal', State};
handle_cast('store_succeeded', State) ->
    lager:debug("store succeeded"),
    {'stop', 'normal', State};
handle_cast('stop', State) ->
    {'stop', 'normal', State};
handle_cast('store_failed', #state{retries=0}=State) ->
    lager:debug("store failed, no more retries."),
    {'stop', 'normal', State};
handle_cast('store_failed', #state{retries=Retries
                                  ,should_store=Store
                                  }=State) ->
    Sleep = ?MILLISECONDS_IN_MINUTE * rand:uniform(10),
    lager:debug("store failed, retrying ~p more times, next in ~p minute(s)"
               ,[Retries, Sleep / ?MILLISECONDS_IN_MINUTE]
               ),
    timer:sleep(Sleep),
    save_recording(State, Store),
    {'noreply', State#state{retries=Retries - 1}};
handle_cast({'gen_listener',{'created_queue', Queue}}, #state{call=Call}=State) ->
    Funs = [{fun kapps_call:kvs_store/3, 'consumer_pid', self()}
           ,{fun kapps_call:kvs_store/3, 'consumer_queue', Queue}
           ,fun kapps_call:clear_helpers/1
           ,{fun kapps_call:set_controller_queue/2, Queue}
           ],
    {'noreply', State#state{call=kapps_call:exec(Funs, Call)}};

handle_cast({'gen_listener',{'is_consuming', 'true'}}, #state{record_on_answer='true'}=State) ->
    lager:debug("waiting for answer to start recording"),
    {'noreply', State};
handle_cast({'gen_listener',{'is_consuming', 'true'}}, #state{record_on_bridge='true'}=State) ->
    lager:debug("waiting for bridge to start recording"),
    {'noreply', State};
handle_cast({'gen_listener',{'is_consuming', 'true'}}, #state{record_on_answer='false'
                                                             ,record_on_bridge='false'
                                                             ,is_recording='false'
                                                             ,call=Call
                                                             ,media={_, MediaName}
                                                             ,time_limit=TimeLimit
                                                             ,sample_rate = SampleRate
                                                             ,record_min_sec = RecordMinSec
                                                             ,doc_id=Id
                                                             }=State) ->
    start_recording(Call, MediaName, TimeLimit, Id, SampleRate, RecordMinSec),
    lager:debug("started the recording"),
    {'noreply', State};

handle_cast({'gen_listener',{'is_consuming', 'true'}}, #state{is_recording='true', call=Call}=State) ->
    lager:notice("appears an AMQP reconnect occured, checking on the channel"),
    _ = kapps_call_command:channel_status(Call),
    {'noreply', State};

handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info({'timeout', TRef, ?RECORDING_TIMER_EXPIRED}, #state{timer_ref=TRef}=State) ->
    lager:notice("the recording's timer expired, stopping the recording"),
    gen_listener:cast(self(), 'stop_recording'),
    {'noreply', State#state{timer_ref='undefined'}};
handle_info({'timeout', TRef, ?RECORDING_STOP_TIMER_EXPIRED}, #state{timer_ref=TRef}=State) ->
    lager:notice("failed to get RECORD_STOP in time, assuming all is lost"),
    {'stop', 'normal', State};
handle_info(_Info, State) ->
    lager:debug("unhandled message: ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), kz_term:proplist()) -> gen_listener:handle_event_return().
handle_event(_JObj, _State) ->
    {'reply', []}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("listener terminating: ~p", [_Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec get_timelimit(kz_term:api_object() | integer()) -> pos_integer().
get_timelimit('undefined') ->
    kz_media_util:max_recording_time_limit();
get_timelimit(TL) when is_integer(TL) ->
    Max = kz_media_util:max_recording_time_limit(),
    case Max > TL of
        'true' -> TL;
        'false' when Max > 0 -> Max;
        'false' -> Max
    end;
get_timelimit(Data) ->
    get_timelimit(kz_json:get_integer_value(<<"time_limit">>, Data)).

-spec get_format(kz_term:api_ne_binary()) -> kz_term:ne_binary().
get_format('undefined') -> kz_media_config:call_recording_extension();
get_format(<<"mp3">> = MP3) -> MP3;
get_format(<<"mp4">> = MP4) -> MP4;
get_format(<<"wav">> = WAV) -> WAV;
get_format(_) -> get_format('undefined').

-spec store_recording_meta(state()) ->
          {'ok', kz_json:object()} |
          kz_datamgr:data_error().
store_recording_meta(#state{call=Call
                           ,format=Ext
                           ,media={_, MediaName}
                           ,doc_modb=AccountMODb
                           ,doc_id=DocId
                           ,cdr_id=CdrId
                           ,interaction_id=InteractionId
                           ,url=Url
                           ,event=EventJObj
                           ,origin=Origin
                           }) ->
    CallId = kapps_call:call_id(Call),
    Timestamp = kz_call_event:timestamp(EventJObj),
    Length = kz_call_event:recording_length(EventJObj),
    Seconds = Length div ?MILLISECONDS_IN_SECOND,
    Start = Timestamp - Seconds,

    BaseMediaDoc = kz_json:from_list(
                     [{<<"_id">>, DocId}
                     ,{<<"call_id">>, CallId}
                     ,{<<"callee_id_name">>, kapps_call:callee_id_name(Call)}
                     ,{<<"callee_id_number">>, kapps_call:callee_id_number(Call)}
                     ,{<<"caller_id_name">>, kapps_call:caller_id_name(Call)}
                     ,{<<"caller_id_number">>, kapps_call:caller_id_number(Call)}
                     ,{<<"cdr_id">>, CdrId}
                     ,{<<"content_type">>, kz_mime:from_extension(Ext)}
                     ,{<<"custom_channel_vars">>, kz_call_event:custom_channel_vars(EventJObj)}
                     ,{<<"description">>, <<"recording ", MediaName/binary>>}
                     ,{<<"direction">>, kapps_call:direction(Call)}
                     ,{<<"duration">>, Seconds}
                     ,{<<"duration_ms">>, Length}
                     ,{<<"from">>, kapps_call:from(Call)}
                     ,{<<"interaction_id">>, InteractionId}
                     ,{<<"media_source">>, <<"recorded">>}
                     ,{<<"media_type">>, Ext}
                     ,{<<"name">>, MediaName}
                     ,{<<"origin">>, Origin}
                     ,{<<"owner_id">>, kapps_call:owner_id(Call)}
                     ,{<<"request">>, kapps_call:request(Call)}
                     ,{<<"source_type">>, kz_term:to_binary(?MODULE)}
                     ,{<<"start">>, Start}
                     ,{<<"to">>, kapps_call:to(Call)}
                     ,{<<"url">>, Url}
                     ]
                    ),

    MediaDoc = kz_doc:update_pvt_parameters(BaseMediaDoc, AccountMODb, [{'type', kzd_call_recordings:type()}]),
    case kazoo_modb:save_doc(AccountMODb, MediaDoc, [{'ensure_saved', 'true'}]) of
        {'ok', Doc} ->
            lager:debug("saved metadata: ~s", [kz_json:encode(Doc)]),
            {'ok', Doc};
        {'error', _E}= Err ->
            lager:warning("failed to save media doc ~s to ~s: ~p", [DocId, AccountMODb, _E]),
            Err
    end.

-spec maybe_store_recording_meta(state()) -> {'ok', kzd_call_recording:doc()} |
          {'error', any()}.
maybe_store_recording_meta(#state{doc_modb=AccountMODb
                                 ,doc_id=DocId
                                 }=State) ->
    case kz_datamgr:open_cache_doc(AccountMODb, {kzd_call_recordings:type(), DocId}) of
        {'ok', Doc} -> {'ok', Doc};
        {'error', _E} ->
            lager:debug("failed to find recording meta ~s in ~s: ~p", [DocId, AccountMODb, _E]),
            store_recording_meta(State)
    end.

-spec get_media_name(kz_term:ne_binary(), kz_term:api_ne_binary()) -> kz_term:ne_binary().
get_media_name(Name, Ext) ->
    case filename:extension(Name) of
        Ext -> Name;
        _ -> <<Name/binary, ".", Ext/binary>>
    end.

-spec store_url(state(), kzd_call_recordings:doc()) -> kz_term:ne_binary().
store_url(#state{doc_modb=AccountMODb
                ,doc_id=MediaId
                ,media={_,MediaName}
                ,format=_Ext
                ,should_store={'true', 'local'}
                }, _MediaDoc) ->
    kz_media_url:store(AccountMODb, {kzd_call_recordings:type(), MediaId}, MediaName, []);
store_url(#state{doc_modb=AccountMODb
                ,doc_id=MediaId
                ,media={_,MediaName}
                ,should_store={'true', 'other', Url}
                ,verb=Verb
                } = State, _MediaDoc) ->
    HandlerOpts = #{url => Url
                   ,verb => Verb
                   ,field_separator => <<>>
                   ,field_list => handler_fields(Url, State)
                   },
    AttHandler = handler_from_url(Url),
    Handler = #{att_proxy => 'true'
               ,att_post_handler => 'external'
               ,att_handler => {AttHandler, HandlerOpts}
               },
    Options = [{'plan_override', Handler}],
    kz_media_url:store(AccountMODb, {kzd_call_recordings:type(), MediaId}, MediaName, Options).

-spec handler_fields(kz_term:ne_binary(), state()) ->
          kz_att_util:format_fields().
handler_fields(Url, State) ->
    {Protocol, _, _, _, _} = kz_http_util:urlsplit(Url),
    handler_fields_for_protocol(Protocol, Url, State).

-spec handler_fields_for_protocol(kz_term:ne_binary(), kz_term:ne_binary(), state()) ->
          kz_att_util:format_fields().
handler_fields_for_protocol(<<"ftp", _/binary>>, _Url, #state{format=Ext}) ->
    [{'const', <<"call_recording_">>}
    ,{'field', <<"call_id">>}
    ,{'const', <<".", Ext/binary>>}
    ];
handler_fields_for_protocol(<<"http", _/binary>>
                           ,Url
                           ,#state{account_id=AccountId
                                  ,format=Ext
                                  ,doc_id=DocId
                                  }
                           ) ->
    {S1, S2} = check_url(Url),
    [{'const', <<S1/binary, "call_recording_">>}, {'field', <<"call_id">>},<<".", Ext/binary>>
    ,{'const', <<S2/binary, "from=">>}, {'field', <<"from">>}
    ,{'const', <<"&to=">>}, {'field', <<"to">>}
    ,{'const', <<"&caller_id_name=">>}, {'field', <<"caller_id_name">>}
    ,{'const', <<"&caller_id_number=">>}, {'field', <<"caller_id_number">>}
    ,{'const', <<"&call_id=">>}, {'field', <<"call_id">>}
    ,{'const', <<"&cdr_id=">>}, {'field', <<"cdr_id">>}
    ,{'const', <<"&interaction_id=">>}, {'field', <<"interaction_id">>}
    ,{'const', <<"&owner_id=">>}, {'field', <<"owner_id">>}
    ,{'const', <<"&account_id=">>}, {'const', AccountId}
    ,{'const', <<"&start=">>}, {'field', <<"start">>}
    ,{'const', <<"&duration_ms=">>}, {'field', <<"duration_ms">>}
    ,{'const', <<"&recording_id=">>}, {'const', DocId}
    ].

-spec check_url(kz_term:ne_binary()) -> {binary(), kz_term:ne_binary()}.
check_url(Url) ->
    case kz_http_util:urlsplit(Url) of
        {_, _, _, <<>>, _} -> {<<>>, <<"?">>};
        {_, _, _, Params, _} -> {check_url_query(Params), <<"&">>}
    end.

-spec check_url_query(kz_term:ne_binary()) -> binary().
check_url_query(Query) ->
    check_url_param(lists:last(binary:split(Query, <<"&">>, ['global']))).

-spec check_url_param(kz_term:ne_binary()) -> binary().
check_url_param(Param) ->
    case binary:split(Param, <<"=">>) of
        [_] -> <<"=">>;
        [_, <<>>] -> <<>>;
        _ -> <<"&recording=">>
    end.

-spec handler_from_url(kz_term:ne_binary()) -> 'kz_att_ftp' | 'kz_att_http' | 'undefined'.
handler_from_url(Url) ->
    case kz_http_util:urlsplit(Url) of
        {<<"ftp">>, _, _, _, _} -> 'kz_att_ftp';
        {<<"ftps">>, _, _, _, _} -> 'kz_att_ftp';
        {<<"http">>, _, _, _, _} -> 'kz_att_http';
        {<<"https">>, _, _, _, _} -> 'kz_att_http';
        _ -> 'undefined'
    end.

-spec should_store_recording(kz_term:ne_binary(), kz_term:api_binary()) -> store_url().
should_store_recording(AccountId, Url) ->
    case kz_term:is_empty(Url) of
        'true' -> maybe_storage_plan(AccountId);
        'false' ->
            case handler_from_url(Url) of
                'undefined' ->
                    lager:debug("invalid protocol for url ~s : not saving attachment"),
                    'false';
                _ -> {'true', 'other', Url}
            end
    end.

-spec maybe_storage_plan(kz_term:ne_binary()) -> store_url().
maybe_storage_plan(AccountId) ->
    AccountDb = kz_util:format_account_mod_id(AccountId),
    Plan = kzs_plan:get_dataplan(AccountDb, <<"call_recording">>),
    case maps:get('tag', Plan, 'local') =/= 'local'
        orelse maps:is_key('att_handler', Plan) of
        'true' -> {'true', 'local'};
        'false' -> should_store_recording()
    end.

-spec should_store_recording() -> store_url().
should_store_recording() ->
    case kz_media_config:should_store_recordings() of
        'true' -> {'true', 'local'};
        'false' -> 'false'
    end.

-spec save_recording(state(), store_url()) -> 'ok'.
save_recording(#state{media={_, MediaName}}, 'false') ->
    lager:info("not configured to store recording ~s", [MediaName]),
    gen_server:cast(self(), 'stop');
save_recording(#state{call=Call
                     ,media=Media
                     }=State, _) ->
    case maybe_store_recording_meta(State) of
        {'error', Err} ->
            lager:warning("error storing metadata : ~p", [Err]),
            gen_server:cast(self(), 'store_failed');
        {'ok', MediaDoc} ->
            StoreUrl = fun() -> store_url(State, MediaDoc) end,
            store_recording(Media, StoreUrl, Call)
    end.

-spec start_recording(kapps_call:call(), kz_term:ne_binary(), pos_integer(), kz_term:ne_binary(), kz_term:api_integer(), kz_term:api_integer()) -> 'ok'.
start_recording(Call, MediaName, TimeLimit, MediaDocId, SampleRate, RecordMinSec) ->
    lager:debug("starting recording of ~s", [MediaName]),
    FollowTransfer = kapps_call:kvs_fetch('recording_follow_transfer', 'true', Call),
    Props = [{<<"Media-Name">>, MediaName}
            ,{<<"Follow-Transfer">>, FollowTransfer}
            ,{<<"Media-Recording-ID">>, MediaDocId}
            ,{<<"Record-Sample-Rate">>, SampleRate}
            ,{<<"Record-Min-Sec">>, kz_term:to_binary(RecordMinSec)}
            ,{<<"Media-Recorder">>, <<"kz_media_recording">>}
            ],
    kapps_call_command:start_record_call(Props, TimeLimit, Call),
    gen_server:cast(self(), 'recording_started').

-spec store_recording({kz_term:ne_binary(), kz_term:ne_binary()}, kapps_call_command:store_fun(), kapps_call:call()) ->
          pid().
store_recording({DirName, MediaName}, StoreUrl, Call) ->
    Filename = filename:join(DirName, MediaName),
    kz_util:spawn(fun store_recording/4, [self(), Filename, StoreUrl, Call]).

-spec store_recording(pid(), kz_term:ne_binary(), kapps_call_command:store_fun(), kapps_call:call()) -> 'ok'.
store_recording(Pid, Filename, StoreUrl, Call) ->
    case kapps_call_command:store_file(Filename, StoreUrl, Call) of
        {'error', Error} ->
            lager:error("error storing recording : ~p", [Error]),
            gen_server:cast(Pid, 'store_failed');
        'ok' -> gen_server:cast(Pid, 'store_succeeded')
    end.

-spec start_recording_timer(pos_integer()) -> reference().
start_recording_timer(TimeLimit) ->
    lager:debug("starting timer for recording for ~ps", [TimeLimit]),
    erlang:start_timer(TimeLimit * ?MILLISECONDS_IN_SECOND
                      ,self()
                      ,?RECORDING_TIMER_EXPIRED
                      ).

-spec start_recording_stop_timer() -> reference().
start_recording_stop_timer() ->
    lager:debug("starting timer while waiting for RECORD_STOP"),
    erlang:start_timer(?RECORDING_STOP_TIMER_EXPIRED_MS
                      ,self()
                      ,?RECORDING_STOP_TIMER_EXPIRED
                      ).

-spec handle_channel_status_resp(kz_json:object(), pid()) -> 'ok'.
handle_channel_status_resp(JObj, Pid) ->
    case kz_json:get_ne_binary_value(<<"Status">>, JObj) of
        <<"active">> -> lager:info("channel is still active");
        _Status ->
            lager:info("channel is ~s, considering it down"),
            gen_listener:cast(Pid, 'channel_destroyed')
    end.

-spec maybe_stop_timer(kz_term:api_reference()) -> 'ok'.
maybe_stop_timer(Ref) when is_reference(Ref) ->
    erlang:cancel_timer(Ref, [{'async', 'true'}
                             ,{'info', 'false'}
                             ]);
maybe_stop_timer('undefined') -> 'ok'.

%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2022, 2600Hz
%%% @doc
%%% @end
%%%-----------------------------------------------------------------------------
-module(stepswitch_bridge).
-behaviour(gen_listener).

-export([start_link/2]).

-export([bridge_emergency_cid_number/1
        ,bridge_outbound_cid_number/1
        ,bridge_emergency_cid_name/1
        ,bridge_outbound_cid_name/1
        ,maybe_override_asserted_identity/2
        ]).

-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-ifdef(TEST).
-export([avoid_privacy_if_emergency_call/2
        ,contains_emergency_endpoints/1
        ]).
-endif.

-include("stepswitch.hrl").
-include_lib("kazoo_amqp/include/kapi_offnet_resource.hrl").
-include_lib("kazoo_number_manager/include/knm_phone_number.hrl").

-define(SERVER, ?MODULE).

-record(state, {endpoints = [] :: stepswitch_resources:endpoints()
               ,resource_req :: kapi_offnet_resource:req()
               ,request_handler :: kz_term:api_pid()
               ,control_queue :: kz_term:api_binary()
               ,response_queue :: kz_term:api_binary()
               ,queue :: kz_term:api_binary()
               ,timeout :: kz_term:api_reference()
               ,call_id :: kz_term:api_binary()
               }).
-type state() :: #state{}.

-define(RESPONDERS, []).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

-define(CALL_BINDING(CallId)
       ,{'call', [{'callid', CallId}
                 ,{'restrict_to',
                   [<<"CHANNEL_DESTROY">>
                   ,<<"CHANNEL_REPLACED">>
                   ,<<"CHANNEL_TRANSFEROR">>
                   ,<<"CHANNEL_EXECUTE_COMPLETE">>
                   ,<<"CHANNEL_BRIDGE">>
                   ,<<"dialplan">>
                   ]
                  }
                 ]
        }
       ).

-define(SHOULD_ENSURE_E911_CID_VALID
       ,kapps_config:get_is_true(?SS_CONFIG_CAT, <<"ensure_valid_emergency_cid">>, 'false')
       ).

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link(stepswitch_resources:endpoints(), kapi_offnet_resource:req()) ->
          kz_types:startlink_ret().
start_link(Endpoints, OffnetReq) ->
    CallId = kapi_offnet_resource:call_id(OffnetReq),
    Bindings = [?CALL_BINDING(CallId)
               ,{'self', []}
               ],
    gen_listener:start_link(?SERVER
                           ,[{'bindings', Bindings}
                            ,{'responders', ?RESPONDERS}
                            ,{'queue_name', ?QUEUE_NAME}
                            ,{'queue_options', ?QUEUE_OPTIONS}
                            ,{'consume_options', ?CONSUME_OPTIONS}
                            ]
                           ,[Endpoints, OffnetReq]
                           ).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([stepswitch_resources:endpoints() | kapi_offnet_resource:req()]) ->
          {'ok', state()}.
init([Endpoints, OffnetReq]) ->
    kapi_offnet_resource:put_callid(OffnetReq),
    case kapi_offnet_resource:control_queue(OffnetReq) of
        'undefined' -> {'stop', 'normal'};
        ControlQ ->
            {'ok', #state{endpoints=Endpoints
                         ,resource_req=OffnetReq
                         ,request_handler=self()
                         ,control_queue=ControlQ
                         ,response_queue=kapi_offnet_resource:server_id(OffnetReq)
                         ,timeout=erlang:send_after(120000, self(), 'bridge_timeout')
                         ,call_id=kapi_offnet_resource:call_id(OffnetReq)
                         }}
    end.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Request, _From, State) ->
    lager:debug("unhandled call: ~p", [_Request]),
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'kz_amqp_channel', _}, State) ->
    {'noreply', State};
handle_cast({'gen_listener', {'created_queue', Q}}, State) ->
    {'noreply', State#state{queue=Q}};
handle_cast({'gen_listener', {'is_consuming', 'true'}}, State) ->
    _ = maybe_bridge(State),
    {'noreply', State};
handle_cast({'bridge_result', _Props}, #state{response_queue='undefined'}=State) ->
    {'stop', 'normal', State};
handle_cast({'bridge_result', Props}, #state{response_queue=ResponseQ}=State) ->
    kapi_offnet_resource:publish_resp(ResponseQ, Props),
    {'stop', 'normal', State};
handle_cast({'bridged', _CallId}, #state{timeout='undefined'}=State) ->
    {'noreply', State};
handle_cast({'bridged', CallId}, #state{timeout=TimerRef}=State) ->
    lager:debug("channel bridged to ~s, canceling timeout", [CallId]),
    _ = erlang:cancel_timer(TimerRef),
    {'noreply', State#state{timeout='undefined'}};
handle_cast({'replaced', ReplacedBy}, #state{}=State) ->
    {'noreply', State#state{call_id=ReplacedBy}};
handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p~n", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info('bridge_timeout', #state{timeout='undefined'}=State) ->
    {'noreply', State};
handle_info('bridge_timeout', #state{response_queue=ResponseQ
                                    ,resource_req=OffnetReq
                                    }=State) ->
    kapi_offnet_resource:publish_resp(ResponseQ, bridge_timeout(OffnetReq)),
    {'stop', 'normal', State#state{timeout='undefined'}};
handle_info(_Info, State) ->
    lager:debug("unhandled info: ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_call_event:doc(), state()) -> gen_listener:handle_event_return().
handle_event(CallEvt, #state{request_handler=RequestHandler
                            ,resource_req=OffnetReq
                            ,call_id=CallId
                            }) ->
    case get_event_type(CallEvt) of
        {<<"error">>, _EvtName, CallId} ->
            handle_error_event(CallEvt, OffnetReq, RequestHandler);
        {<<"call_event">>, <<"CHANNEL_TRANSFEROR">>, _} ->
            handle_channel_transferor(CallEvt, RequestHandler);
        {<<"call_event">>, <<"CHANNEL_REPLACED">>, _} ->
            handle_channel_replaced(CallEvt, RequestHandler);
        {<<"call_event">>, <<"CHANNEL_DESTROY">>, CallId} ->
            handle_channel_destroy(CallEvt, OffnetReq, RequestHandler);
        {<<"call_event">>, <<"CHANNEL_EXECUTE_COMPLETE">>, CallId} ->
            handle_channel_execute_complete(CallEvt, OffnetReq, RequestHandler);
        {<<"call_event">>, <<"CHANNEL_BRIDGE">>, CallId} ->
            handle_channel_bridge(CallEvt, RequestHandler);
        _ -> 'ok'
    end,
    {'reply', []}.

-spec handle_channel_bridge(kz_call_event:doc(), kz_term:api_pid()) -> 'ok'.
handle_channel_bridge(CallEvt, RequestHandler) ->
    OtherLeg = kz_call_event:other_leg_call_id(CallEvt),
    gen_listener:cast(RequestHandler, {'bridged', OtherLeg}).

-spec handle_channel_transferor(kz_call_event:doc(), kz_term:api_pid()) -> 'ok'.
handle_channel_transferor(CallEvt, RequestHandler) ->
    Transferor = kz_call_event:other_leg_call_id(CallEvt),
    lager:info("channel_transferor to ~s", [Transferor]),
    follow_call_id(RequestHandler, Transferor).

-spec handle_channel_replaced(kz_call_event:doc(), kz_term:api_pid()) -> 'ok'.
handle_channel_replaced(CallEvt, RequestHandler) ->
    ReplacedBy = kz_call_event:replaced_by(CallEvt),
    lager:info("channel_replaced to ~s", [ReplacedBy]),
    follow_call_id(RequestHandler, ReplacedBy).

-spec follow_call_id(kz_term:api_pid(), kz_term:ne_binary()) -> 'ok'.
follow_call_id(RequestHandler, CallId) ->
    gen_listener:cast(RequestHandler, {'replaced', CallId}),
    gen_listener:add_binding(RequestHandler, ?CALL_BINDING(CallId)).

-spec handle_error_event(kz_call_event:doc(), kapi_offnet_resource:req(), kz_term:api_pid()) -> 'ok'.
handle_error_event(CallEvt, OffnetReq, RequestHandler) ->
    handle_error_event(CallEvt
                      ,OffnetReq
                      ,RequestHandler
                      ,kapi_dialplan:application_name(kz_call_event:request(CallEvt))
                      ).

-spec handle_error_event(kz_call_event:doc(), kapi_offnet_resource:req(), kz_term:api_pid(), kz_term:ne_binary()) -> 'ok'.
handle_error_event(CallEvt, OffnetReq, RequestHandler, <<"bridge">>) ->
    lager:info("channel execution error while waiting for bridge: ~s"
              ,[kz_term:to_binary(kz_json:encode(CallEvt))]
              ),
    gen_listener:cast(RequestHandler, {'bridge_result', bridge_error(CallEvt, OffnetReq)});
handle_error_event(_CallEvt, _OffnetReq, _RequestHandler, _EvtName) ->
    lager:debug("ignoring execution error of ~s", [_EvtName]).

-spec handle_channel_destroy(kz_call_event:doc(), kapi_offnet_resource:req(), kz_term:api_pid()) -> 'ok'.
handle_channel_destroy(CallEvt, OffnetReq, RequestHandler) ->
    lager:debug("channel was destroyed while waiting for bridge"),
    handle_bridge_result(CallEvt, OffnetReq, RequestHandler).

-spec handle_channel_execute_complete(kz_call_event:doc(), kapi_offnet_resource:req(), kz_term:api_pid()) -> 'ok'.
handle_channel_execute_complete(CallEvt, OffnetReq, RequestHandler) ->
    handle_channel_execute_complete(CallEvt
                                   ,OffnetReq
                                   ,RequestHandler
                                   ,kz_call_event:application_name(CallEvt)
                                   ).

-spec handle_channel_execute_complete(kz_call_event:doc(), kapi_offnet_resource:req(), kz_term:api_pid(), kz_term:api_ne_binary()) -> 'ok'.
handle_channel_execute_complete(CallEvt, OffnetReq, RequestHandler, <<"bridge">>) ->
    lager:debug("channel execute complete for bridge"),
    handle_bridge_result(CallEvt, OffnetReq, RequestHandler);
handle_channel_execute_complete(_CallEvt, _OffnetReq, _RequestHander, _AppName) ->
    lager:debug("ignoring channel_execute_complete for application ~s", [_AppName]).

-spec handle_bridge_result(kz_call_event:doc(), kapi_offnet_resource:req(), kz_term:api_pid()) -> 'ok'.
handle_bridge_result(CallEvt, OffnetReq, RequestHandler) ->
    Result = case <<"SUCCESS">> =:= kz_call_event:disposition(CallEvt) of
                 'true' -> bridge_success(CallEvt, OffnetReq);
                 'false' -> bridge_failure(CallEvt, OffnetReq)
             end,
    gen_listener:cast(RequestHandler, {'bridge_result', Result}).

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
-spec maybe_bridge(state()) -> 'ok'.
maybe_bridge(#state{endpoints=Endpoints
                   ,resource_req=OffnetReq
                   ,control_queue=ControlQ
                   }=State) ->
    case contains_emergency_endpoints(Endpoints) of
        'true' ->
            maybe_bridge_emergency(State);
        'false' ->
            Name = bridge_outbound_cid_name(OffnetReq),
            Number = bridge_outbound_cid_number(OffnetReq),
            kapi_dialplan:publish_command(ControlQ
                                         ,build_bridge(State, Number, Name, 'false')
                                         ),
            lager:debug("sent bridge command to ~s", [ControlQ])
    end.

-spec maybe_bridge_emergency(state()) -> 'ok'.
maybe_bridge_emergency(#state{resource_req=OffnetReq
                             ,control_queue=ControlQ
                             }=State) ->
    %% NOTE: if this request had a hunt-account-id then we
    %%   are assuming it was for a local resource (at the
    %%   time of this commit offnet DB is still in use)
    Name = bridge_emergency_cid_name(OffnetReq),
    case kapi_offnet_resource:hunt_account_id(OffnetReq) of
        'undefined' ->
            Number = find_emergency_number(OffnetReq),
            maybe_deny_emergency_bridge(State, Number, Name);
        _Else ->
            Number = bridge_emergency_cid_number(OffnetReq),
            lager:debug("not enforcing emergency caller id validation when using resource from account ~s", [_Else]),
            kapi_dialplan:publish_command(ControlQ, build_bridge(State, Number, Name, 'true')),
            lager:debug("sent bridge command to ~s", [ControlQ])
    end.

-spec maybe_deny_emergency_bridge(state(), kz_term:api_binary(), kz_term:api_binary()) -> 'ok'.
maybe_deny_emergency_bridge(#state{resource_req=OffnetReq}=State, 'undefined', Name) ->
    AccountId = kapi_offnet_resource:account_id(OffnetReq),
    case kapps_config:get_is_true(?SS_CONFIG_CAT
                                 ,<<"deny_invalid_emergency_cid">>
                                 ,'false'
                                 )
    of
        'true' -> deny_emergency_bridge(State);
        'false' ->
            Number = default_emergency_number(kz_privacy:anonymous_caller_id_number(AccountId)),
            maybe_deny_emergency_bridge(State, Number, Name)
    end;
maybe_deny_emergency_bridge(#state{control_queue=ControlQ
                                  ,endpoints=Endpoints
                                  }=State, Number, Name) ->
    _ = send_emergency_bridge_notification(Number, State),
    UpdatedEndpoints = update_endpoints_emergency_cid(Endpoints, Number, Name),
    kapi_dialplan:publish_command(ControlQ
                                 ,build_bridge(State#state{endpoints=UpdatedEndpoints}, Number, Name, 'true')
                                 ),
    lager:debug("sent bridge command to ~s", [ControlQ]).

-spec update_endpoints_emergency_cid(stepswitch_resources:endpoints(), kz_term:ne_binary(), kz_term:api_ne_binary()) ->
          stepswitch_resources:endpoints().
update_endpoints_emergency_cid(Endpoints, Number, Name) ->
    [update_endpoint_emergency_cid(Endpoint, Number, Name)
     || Endpoint <- Endpoints
    ].

-spec update_endpoint_emergency_cid(stepswitch_resources:endpoint(), kz_term:ne_binary(), kz_term:api_binary()) -> stepswitch_resources:endpoint().
update_endpoint_emergency_cid(Endpoint, Number, Name) ->
    case {kz_json:get_ne_binary_value(<<"Outbound-Caller-ID-Number">>, Endpoint, Number)
         ,kz_json:get_ne_binary_value(<<"Outbound-Caller-ID-Name">>, Endpoint, Name)
         }
    of
        {Number, Name} -> Endpoint;
        {Number, _} -> kz_json:set_value(<<"Outbound-Caller-ID-Name">>, Name, Endpoint);
        {_, Name} -> kz_json:set_value(<<"Outbound-Caller-ID-Number">>, Number, Endpoint);
        {_, _} ->
            Props = [{<<"Outbound-Caller-ID-Name">>, Name}
                    ,{<<"Outbound-Caller-ID-Number">>, Number}
                    ],
            kz_json:set_values(Props, Endpoint)
    end.

-spec outbound_flags(kapi_offnet_resource:req()) -> kz_term:api_binary().
outbound_flags(OffnetReq) ->
    case kapi_offnet_resource:flags(OffnetReq) of
        [] -> 'undefined';
        Flags -> kz_binary:join(Flags, <<"|">>)
    end.

-spec build_bridge(state(), kz_term:api_binary(), kz_term:api_binary(), boolean()) ->
          kz_term:proplist().
build_bridge(#state{endpoints=Endpoints
                   ,resource_req=OffnetReq
                   ,queue=Q
                   }
            ,Number
            ,Name
            ,IsEmergency
            ) ->
    lager:debug("set outbound caller id to ~s '~s'", [Number, Name]),
    AccountId = kapi_offnet_resource:account_id(OffnetReq),

    ReqCCVs = kapi_offnet_resource:custom_channel_vars(OffnetReq, kz_json:new()),

    IgnoreEarlyMedia = kz_json:is_true(<<"Require-Ignore-Early-Media">>, ReqCCVs, 'false')
        orelse kapi_offnet_resource:ignore_early_media(OffnetReq, 'false'),

    FailOnSingleReject = kz_json:get_value(<<"Require-Fail-On-Single-Reject">>, ReqCCVs),

    AddCCVs = props:filter_undefined([{<<"Ignore-Display-Updates">>, <<"true">>}
                                     ,{<<"Account-ID">>, AccountId}
                                     ,{<<"From-URI">>, bridge_from_uri(Number, OffnetReq)}
                                     ,{<<"Realm">>, stepswitch_util:default_realm(OffnetReq)}
                                     ,{<<"Reseller-ID">>, kz_services_reseller:get_id(AccountId)}
                                     ,{<<"Outbound-Flags">>, outbound_flags(OffnetReq)}
                                     ]),
    RemoveCCVs = [{<<"Require-Ignore-Early-Media">>, 'null'}
                 ,{<<"Require-Fail-On-Single-Reject">>, 'null'}
                 ],

    NewEndpoints = avoid_privacy_if_emergency_call(IsEmergency, Endpoints),
    CCVs = kz_json:set_values(AddCCVs ++ RemoveCCVs, ReqCCVs),
    FmtEndpoints = stepswitch_util:format_endpoints(NewEndpoints, Name, Number, OffnetReq),

    Realm = kzd_accounts:fetch_realm(AccountId),

    {AssertedNumber, AssertedName} = maybe_override_asserted_identity(OffnetReq, {IsEmergency, Number, Name}),

    props:filter_undefined(
      [{<<"Application-Name">>, <<"bridge">>}
      ,{<<"Asserted-Identity-Name">>, AssertedName}
      ,{<<"Asserted-Identity-Number">>, AssertedNumber}
      ,{<<"Asserted-Identity-Realm">>, kapi_offnet_resource:asserted_identity_realm(OffnetReq, Realm)}
      ,{<<"B-Leg-Events">>, kapi_offnet_resource:b_leg_events(OffnetReq, [])}
      ,{<<"Bridge-Actions">>, kapi_offnet_resource:outbound_actions(OffnetReq)}
      ,{<<"Call-ID">>, kapi_offnet_resource:call_id(OffnetReq)}
      ,{<<"Caller-ID-Name">>, Name}
      ,{<<"Caller-ID-Number">>, Number}
      ,{<<"Custom-Application-Vars">>, kapi_offnet_resource:custom_application_vars(OffnetReq)}
      ,{<<"Custom-Channel-Vars">>, CCVs}
      ,{<<"Dial-Endpoint-Method">>, <<"single">>}
      ,{<<"Endpoints">>, FmtEndpoints}
      ,{<<"Fail-On-Single-Reject">>, FailOnSingleReject}
      ,{<<"Fax-Identity-Name">>, kapi_offnet_resource:fax_identity_name(OffnetReq, Name)}
      ,{<<"Fax-Identity-Number">>, kapi_offnet_resource:fax_identity_number(OffnetReq, Number)}
      ,{<<"Hold-Media">>, kapi_offnet_resource:hold_media(OffnetReq)}
      ,{<<"Ignore-Early-Media">>, IgnoreEarlyMedia}
      ,{<<"Media">>, kapi_offnet_resource:media(OffnetReq)}
      ,{<<"Outbound-Callee-ID-Name">>, kapi_offnet_resource:outbound_callee_id_name(OffnetReq)}
      ,{<<"Outbound-Callee-ID-Number">>, kapi_offnet_resource:outbound_callee_id_number(OffnetReq)}
      ,{<<"Presence-ID">>, kapi_offnet_resource:presence_id(OffnetReq)}
      ,{<<"Ringback">>, kapi_offnet_resource:ringback(OffnetReq)}
      ,{<<"Timeout">>, kapi_offnet_resource:timeout(OffnetReq)}
      ,{?KEY_OUTBOUND_CALLER_ID_NAME, Name}
      ,{?KEY_OUTBOUND_CALLER_ID_NUMBER, Number}
       | kz_api:default_headers(Q, <<"call">>, <<"command">>, ?APP_NAME, ?APP_VERSION)
      ]).

-type emergency_override() :: {boolean(), kz_term:api_binary(), kz_term:api_binary()}.
-type caller_id() :: {kz_term:api_ne_binary(), kz_term:api_ne_binary()}.

-spec maybe_override_asserted_identity(kapi_offnet_resource:req(), emergency_override()) -> caller_id().
maybe_override_asserted_identity(OffnetReq, {'false', _Number, _Name}) ->
    {kapi_offnet_resource:asserted_identity_number(OffnetReq)
    ,kapi_offnet_resource:asserted_identity_name(OffnetReq)
    };
maybe_override_asserted_identity(OffnetReq, {'true', Number, Name}) ->
    AssertedNumber = kapi_offnet_resource:asserted_identity_number(OffnetReq),
    AssertedName = kapi_offnet_resource:asserted_identity_name(OffnetReq),
    case kz_term:is_empty(AssertedNumber)
        orelse kz_term:is_empty(AssertedName)
    of
        'true' -> {'undefined', 'undefined'};
        'false' -> {Number, Name}
    end.

-spec bridge_from_uri(kz_term:api_binary(), kapi_offnet_resource:req()) ->
          kz_term:api_binary().
bridge_from_uri(Number, OffnetReq) ->
    Realm = stepswitch_util:default_realm(OffnetReq),

    case (kapps_config:get_is_true(?SS_CONFIG_CAT, <<"format_from_uri">>, 'false')
          orelse kapi_offnet_resource:format_from_uri(OffnetReq)
         )
        andalso is_binary(Number)
        andalso is_binary(Realm)
    of
        'false' -> 'undefined';
        'true' ->
            FromURI = <<"sip:", Number/binary, "@", Realm/binary>>,
            lager:debug("setting bridge from-uri to ~s", [FromURI]),
            FromURI
    end.

-spec bridge_outbound_cid_name(kapi_offnet_resource:req()) -> kz_term:api_binary().
bridge_outbound_cid_name(OffnetReq) ->
    case kapi_offnet_resource:outbound_caller_id_name(OffnetReq) of
        'undefined' -> kapi_offnet_resource:emergency_caller_id_name(OffnetReq);
        Name -> Name
    end.

-spec bridge_outbound_cid_number(kapi_offnet_resource:req()) -> kz_term:api_binary().
bridge_outbound_cid_number(OffnetReq) ->
    case kapi_offnet_resource:outbound_caller_id_number(OffnetReq) of
        'undefined' -> kapi_offnet_resource:emergency_caller_id_number(OffnetReq);
        Number -> Number
    end.

-spec bridge_emergency_cid_name(kapi_offnet_resource:req()) -> kz_term:api_binary().
bridge_emergency_cid_name(OffnetReq) ->
    case kapi_offnet_resource:emergency_caller_id_name(OffnetReq) of
        'undefined' -> kapi_offnet_resource:outbound_caller_id_name(OffnetReq);
        Name -> Name
    end.

-spec bridge_emergency_cid_number(kapi_offnet_resource:req()) -> kz_term:api_ne_binary().
bridge_emergency_cid_number(OffnetReq) ->
    case kapi_offnet_resource:emergency_caller_id_number(OffnetReq) of
        'undefined' -> kapi_offnet_resource:outbound_caller_id_number(OffnetReq);
        Number -> Number
    end.

-spec find_emergency_number(kapi_offnet_resource:req()) -> kz_term:api_binary().
find_emergency_number(OffnetReq) ->
    case ?SHOULD_ENSURE_E911_CID_VALID of
        'true' -> ensure_valid_emergency_number(OffnetReq);
        'false' ->
            lager:debug("using first configured unverified emergency caller id"),
            bridge_emergency_cid_number(OffnetReq)
    end.

-spec ensure_valid_emergency_number(kapi_offnet_resource:req()) -> kz_term:api_ne_binary().
ensure_valid_emergency_number(OffnetReq) ->
    AccountId = kapi_offnet_resource:account_id(OffnetReq),
    lager:debug("ensuring emergency caller is valid for account ~s", [AccountId]),
    Numbers = knm_numbers:emergency_enabled(AccountId),
    Emergency = bridge_emergency_cid_number(OffnetReq),
    Outbound = bridge_outbound_cid_number(OffnetReq),
    case {lists:member(Emergency, Numbers), lists:member(Outbound, Numbers)} of
        {'true', _} ->
            lager:info("determined emergency caller id number ~s is configured for e911", [Emergency]),
            Emergency;
        {_, 'true'} ->
            lager:info("determined outbound caller id number ~s is configured for e911", [Outbound]),
            Outbound;
        {'false', 'false'} ->
            lager:notice("emergency caller id number ~s nor outbound caller id number ~s configured for e911"
                        ,[Emergency, Outbound]
                        ),
            find_valid_emergency_number(Numbers)
    end.

-spec find_valid_emergency_number(kz_term:ne_binaries()) -> kz_term:api_ne_binary().
find_valid_emergency_number([]) ->
    lager:info("no alternative e911 enabled numbers available"),
    'undefined';
find_valid_emergency_number([Number|_]) ->
    lager:info("found alternative emergency caller id number ~s", [Number]),
    Number.

-spec default_emergency_number(kz_term:ne_binary()) -> kz_term:ne_binary().
default_emergency_number(Requested) ->
    case ?DEFAULT_EMERGENCY_CID_NUMBER of
        'undefined' -> Requested;
        Else -> Else
    end.

-spec contains_emergency_endpoints(stepswitch_resources:endpoints()) -> boolean().
contains_emergency_endpoints(Endpoints) ->
    lists:any(fun is_emergency_endpoint/1, Endpoints).

-spec is_emergency_endpoint(boolean() | stepswitch_resources:endpoint()) -> boolean().
is_emergency_endpoint('true') ->
    lager:debug("endpoints contain an emergency resource"),
    'true';
is_emergency_endpoint('false') -> 'false';
is_emergency_endpoint(Endpoint) ->
    is_emergency_endpoint(kz_json:is_true([?KEY_CCVS, ?KEY_EMERGENCY_RESOURCE], Endpoint)).

-spec bridge_timeout(kapi_offnet_resource:req()) -> kz_term:proplist().
bridge_timeout(OffnetReq) ->
    lager:debug("attempt to connect to resources timed out"),
    [{<<"Call-ID">>, kapi_offnet_resource:call_id(OffnetReq)}
    ,{<<"Msg-ID">>, kapi_offnet_resource:msg_id(OffnetReq)}
    ,{<<"Response-Message">>, <<"NORMAL_TEMPORARY_FAILURE">>}
    ,{<<"Response-Code">>, <<"sip:500">>}
    ,{<<"Error-Message">>, <<"bridge request timed out">>}
    ,{<<"To-DID">>, kapi_offnet_resource:to_did(OffnetReq)}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec bridge_error(kz_call_event:doc(), kapi_offnet_resource:req()) -> kz_term:proplist().
bridge_error(CallEvt, OffnetReq) ->
    lager:debug("error during outbound request: ~s", [kz_json:encode(CallEvt)]),

    [{<<"Call-ID">>, kapi_offnet_resource:call_id(OffnetReq)}
    ,{<<"Msg-ID">>, kapi_offnet_resource:msg_id(OffnetReq)}
    ,{<<"Response-Message">>, <<"NORMAL_TEMPORARY_FAILURE">>}
    ,{<<"Response-Code">>, <<"sip:500">>}
    ,{<<"Error-Message">>, kz_call_event:error_message(CallEvt, <<"failed to process request">>)}
    ,{<<"To-DID">>, kapi_offnet_resource:to_did(OffnetReq)}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec bridge_success(kz_call_event:doc(), kapi_offnet_resource:req()) -> kz_term:proplist().
bridge_success(CallEvt, OffnetReq) ->
    lager:debug("outbound request successfully completed"),
    [{<<"Call-ID">>, kapi_offnet_resource:call_id(OffnetReq)}
    ,{<<"Msg-ID">>, kapi_offnet_resource:msg_id(OffnetReq)}
    ,{<<"Response-Message">>, <<"SUCCESS">>}
    ,{<<"Response-Code">>, <<"sip:200">>}
    ,{<<"Resource-Response">>, CallEvt}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec bridge_failure(kz_call_event:doc(), kapi_offnet_resource:req()) -> kz_term:proplist().
bridge_failure(CallEvt, OffnetReq) ->
    lager:debug("resources for outbound request failed: ~s"
               ,[kz_call_event:disposition(CallEvt)]
               ),
    [{<<"Call-ID">>, kapi_offnet_resource:call_id(OffnetReq)}
    ,{<<"Msg-ID">>, kapi_offnet_resource:msg_id(OffnetReq)}
    ,{<<"Response-Message">>, response_message(CallEvt)}
    ,{<<"Response-Code">>, kz_call_event:hangup_code(CallEvt)}
    ,{<<"Resource-Response">>, CallEvt}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec response_message(kz_call_event:doc()) -> kz_term:api_ne_binary().
response_message(CallEvt) ->
    case kz_call_event:application_response(CallEvt) of
        'undefined' -> kz_call_event:hangup_cause(CallEvt);
        AppResp -> AppResp
    end.

-spec bridge_not_configured(kapi_offnet_resource:req()) -> kz_term:proplist().
bridge_not_configured(OffnetReq) ->
    [{<<"Call-ID">>, kapi_offnet_resource:call_id(OffnetReq)}
    ,{<<"Msg-ID">>, kapi_offnet_resource:msg_id(OffnetReq)}
    ,{<<"Response-Message">>, <<"MANDATORY_IE_MISSING">>}
    ,{<<"Response-Code">>, <<"sip:403">>}
    ,{<<"Error-Message">>, <<"services not configured">>}
    ,{<<"To-DID">>, kapi_offnet_resource:to_did(OffnetReq)}
     | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
    ].

-spec deny_emergency_bridge(state()) -> 'ok'.
deny_emergency_bridge(#state{resource_req=OffnetReq
                            ,control_queue=ControlQ
                            }) ->
    lager:warning("terminating attempted emergency bridge from unconfigured device"),
    _ = send_deny_emergency_response(OffnetReq, ControlQ),
    send_deny_emergency_notification(OffnetReq),
    Result = bridge_not_configured(OffnetReq),
    gen_listener:cast(self(), {'bridge_result', Result}).

-spec send_deny_emergency_notification(kapi_offnet_resource:req()) -> 'ok'.
send_deny_emergency_notification(OffnetReq) ->
    Props =
        [{<<"Call-ID">>, kapi_offnet_resource:call_id(OffnetReq)}
        ,{<<"Account-ID">>, kapi_offnet_resource:account_id(OffnetReq)}
        ,{?KEY_E_CALLER_ID_NUMBER, kapi_offnet_resource:emergency_caller_id_number(OffnetReq)}
        ,{?KEY_E_CALLER_ID_NAME, kapi_offnet_resource:emergency_caller_id_name(OffnetReq)}
        ,{?KEY_OUTBOUND_CALLER_ID_NUMBER, kapi_offnet_resource:outbound_caller_id_number(OffnetReq)}
        ,{?KEY_OUTBOUND_CALLER_ID_NAME, kapi_offnet_resource:outbound_caller_id_name(OffnetReq)}
         | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
        ],
    kapps_notify_publisher:cast(Props, fun kapi_notifications:publish_denied_emergency_bridge/1).

-spec send_deny_emergency_response(kapi_offnet_resource:req(), kz_term:ne_binary()) ->
          {'ok', kz_term:ne_binary()} |
          {'error', 'no_response'}.
send_deny_emergency_response(OffnetReq, ControlQ) ->
    CallId = kapi_offnet_resource:call_id(OffnetReq),
    Code = kapps_config:get_integer(?SS_CONFIG_CAT, <<"deny_emergency_bridge_code">>, 486),
    Cause = kapps_config:get_ne_binary(?SS_CONFIG_CAT
                                      ,<<"deny_emergency_bridge_cause">>
                                      ,<<"Emergency service not configured">>
                                      ),
    Media = kapps_config:get_ne_binary(?SS_CONFIG_CAT
                                      ,<<"deny_emergency_bridge_media">>
                                      ,<<"prompt://system_media/stepswitch-emergency_not_configured/">>
                                      ),
    kz_call_response:send(CallId, ControlQ, Code, Cause, Media).

-spec send_emergency_bridge_notification(kz_term:ne_binary(), state()) -> 'ok'.
send_emergency_bridge_notification(Number, #state{resource_req=OffnetReq}=State) ->
    Setters = [{fun set_emergency_call_meta/2, {Number, State}}
              ,{fun set_emergency_device_meta/2, OffnetReq}
              ,{fun set_emergency_address_meta/2, {Number, OffnetReq}}
              ,{fun set_emergency_user_meta/2, OffnetReq}
              ,{fun set_default_headers/2, OffnetReq}
              ],

    Props = lists:foldl(fun({F, O}, A) -> F(O, A) end, [], Setters),
    kapps_notify_publisher:cast(Props, fun kapi_notifications:publish_emergency_bridge/1).

-spec set_default_headers(kapi_offnet_resource:req(), kz_term:proplist()) -> kz_term:proplist().
set_default_headers(_OffnetReq, Props) ->
    Props ++ kz_api:default_headers(?APP_NAME, ?APP_VERSION).

-spec set_emergency_call_meta({kz_term:ne_binary(), state()}, kz_term:proplist()) -> kz_term:proplist().
set_emergency_call_meta({Number, #state{resource_req=OffnetReq}=State}, Props) ->
    [{<<"Call-ID">>, kapi_offnet_resource:call_id(OffnetReq)}
    ,{<<"Account-ID">>, kapi_offnet_resource:account_id(OffnetReq)}
    ,{?KEY_E_CALLER_ID_NUMBER, Number}
    ,{?KEY_E_CALLER_ID_NAME, kapi_offnet_resource:emergency_caller_id_name(OffnetReq)}
    ,{?KEY_OUTBOUND_CALLER_ID_NUMBER, kapi_offnet_resource:outbound_caller_id_number(OffnetReq)}
    ,{?KEY_OUTBOUND_CALLER_ID_NAME, kapi_offnet_resource:outbound_caller_id_name(OffnetReq)}
    ,{<<"Emergency-Test-Call">>, maybe_emergency_test_call(State)}
    ,{<<"Emergency-To-DID">>, kapi_offnet_resource:to_did(OffnetReq)}
     | Props
    ].


-spec set_emergency_device_meta(kapi_offnet_resource:req(), kz_term:proplist()) -> kz_term:proplist().
set_emergency_device_meta(OffnetReq, Props) ->
    AccountID = kapi_offnet_resource:account_id(OffnetReq),
    DeviceID = kz_json:get_ne_value(<<"Authorizing-ID">>, kapi_offnet_resource:requestor_custom_channel_vars(OffnetReq), 'undefined'),
    OwnerID =kz_json:get_ne_value(<<"Owner-ID">>, kapi_offnet_resource:requestor_custom_channel_vars(OffnetReq), 'undefined'),
    {'ok', DeviceJObj} = kzd_devices:fetch(AccountID, DeviceID),
    [{<<"Authorizing-ID">>, DeviceID}
    ,{<<"Owner-ID">>, OwnerID}
    ,{<<"Device-Name">>, kzd_devices:name(DeviceJObj)}
     | Props
    ].

-spec set_emergency_address_meta({kz_term:ne_binary(), kapi_offnet_resource:req()}, kz_term:proplist()) -> kz_term:proplist().
set_emergency_address_meta({Number, OffnetReq}, Props) ->
    AccountDB = kz_util:format_account_db(kapi_offnet_resource:account_id(OffnetReq)),
    case kz_datamgr:open_doc(AccountDB, Number) of
        {'ok', Doc} ->
            [{<<"Emergency-Address-Street-1">>, extract_e911_street_address_field(Doc, <<"street_address">>)}
            ,{<<"Emergency-Address-Street-2">>,  extract_e911_street_address_field(Doc, <<"street_address_extended">>)}
            ,{<<"Emergency-Address-City">>,  kzd_phone_numbers:e911_locality(Doc)}
            ,{<<"Emergency-Address-Latitude">>, kzd_phone_numbers:e911_latitude(Doc)}
            ,{<<"Emergency-Address-Longitude">>, kzd_phone_numbers:e911_latitude(Doc)}
            ,{<<"Emergency-Address-Region">>,  kzd_phone_numbers:e911_region(Doc)}
            ,{<<"Emergency-Address-Postal-Code">>,  kzd_phone_numbers:e911_postal_code(Doc)}
            ,{<<"Emergency-Notfication-Contact-Emails">>, kzd_phone_numbers:e911_notification_contact_emails(Doc)}
             | Props
            ];
        {'error', _} -> Props
    end.

-spec maybe_emergency_test_call(state()) -> boolean().
maybe_emergency_test_call(#state{endpoints=Endpoints
                                ,resource_req=OffnetReq
                                }=_State) ->
    is_resource_test_rule(Endpoints, kapi_offnet_resource:to_did(OffnetReq)).

-spec is_resource_test_rule(stepswitch_resources:endpoints(), kz_term:ne_binary()) -> boolean().
is_resource_test_rule(Endpoints, To) ->
    is_resource_test_rule(Endpoints, To, 'false').

-spec is_resource_test_rule(stepswitch_resources:endpoints(), kz_term:ne_binary(), boolean()) -> boolean().
is_resource_test_rule([], _To, Acc) -> Acc;
is_resource_test_rule([E | Rest], To, Acc) ->
    ResourceId = kz_json:get_ne_value([<<"Custom-Channel-Vars">>, <<"Resource-ID">>], E),
    Match = stepswitch_resources:is_test_number(To, ResourceId),
    is_resource_test_rule(Rest, To, Match or Acc).

-spec extract_e911_street_address_field(kz_doc:doc(), kz_term:ne_binary()) -> kz_term:ne_binary() | 'undefined'.
extract_e911_street_address_field(Doc, Key) ->
    JObj = kzd_phone_numbers:e911(Doc),
    case kz_json:get_ne_value(Key, JObj) of
        'undefined' -> maybe_use_e911_legacy_value(Doc, Key);
        Value -> Value
    end.

-spec maybe_use_e911_legacy_value(kz_doc:doc(), kz_term:ne_binary()) -> kz_term:ne_binary() | 'undefined'.
maybe_use_e911_legacy_value(Doc, <<"street_address">>) ->
    format_legacy_address(kzd_phone_numbers:e911_legacy_data_house_number(Doc)
                         ,kzd_phone_numbers:e911_legacy_data_streetname(Doc)
                         );
maybe_use_e911_legacy_value(Doc, <<"street_address_extended">>) ->
    kzd_phone_numbers:e911_legacy_data_suite(Doc).

-spec format_legacy_address(kz_term:api_ne_binary(), kz_term:api_ne_binary()) -> kz_term:api_ne_binary().
format_legacy_address('undefined', 'undefined') ->
    'undefined';
format_legacy_address('undefined', Street) ->
    Street;
format_legacy_address(House, 'undefined') ->
    House;
format_legacy_address(House, Street) ->
    <<(House)/binary, " ", (Street)/binary>>.

-spec set_emergency_user_meta(kapi_offnet_resource:req(), kz_term:proplist()) -> kz_term:proplist().
set_emergency_user_meta(OffnetReq, Props) ->
    AccountID = kapi_offnet_resource:account_id(OffnetReq),
    OwnerID =kz_json:get_ne_value(<<"Owner-ID">>, kapi_offnet_resource:requestor_custom_channel_vars(OffnetReq), 'undefined'),
    case kzd_users:fetch(AccountID, OwnerID) of
        {'ok', UserJObj} ->
            [{<<"User-First-Name">>, kzd_users:first_name(UserJObj)}
            ,{<<"User-Last-Name">>, kzd_users:last_name(UserJObj)}
            ,{<<"User-Email">>, kzd_users:email(UserJObj)}
             | Props
            ];
        {'error', _} -> Props
    end.

-spec get_event_type(kz_call_event:doc()) ->
          {kz_term:ne_binary(), kz_term:ne_binary(), kz_term:ne_binary()}.
get_event_type(CallEvt) ->
    {Cat, Name} = kz_util:get_event_type(CallEvt),
    {Cat, Name, kz_call_event:call_id(CallEvt)}.


%%------------------------------------------------------------------------------
%% @doc If it is an emergency call (i.e 911 call) don't honor `privacy' settings.
%% @end
%%------------------------------------------------------------------------------
-spec avoid_privacy_if_emergency_call(boolean(), stepswitch_resources:endpoints()) -> stepswitch_resources:endpoints().
avoid_privacy_if_emergency_call('true', Endpoints) ->
    lager:info("emergency call ongoing, ignoring privacy settings"),
    Values = [{?KEY_PRIVACY_HIDE_NAME, 'false'}
             ,{?KEY_PRIVACY_HIDE_NUMBER, 'false'}
             ,{?KEY_PRIVACY_METHOD, <<"none">>}
             ],
    F = fun(E, Acc) -> [kz_json:set_values(Values, E) | Acc] end,
    lists:foldl(F, [], Endpoints);
avoid_privacy_if_emergency_call('false', Endpoints) ->
    Endpoints.

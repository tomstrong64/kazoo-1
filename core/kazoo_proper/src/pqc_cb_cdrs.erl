-module(pqc_cb_cdrs).

%% Manual testing
-export([seq/0, big_dataset_seq/0, straight_seq/0
        ,cleanup/0
        ]).

%% API Shims
-export([summary/2, summary/3
        ,fetch/3
        ]).

-export([interactions/2
        ,legs/3
        ]).

-include_lib("proper/include/proper.hrl").
-include("kazoo_proper.hrl").
-include_lib("kazoo_stdlib/include/kz_databases.hrl").

-define(ACCOUNT_NAMES, [<<?MODULE_STRING>>]).
-define(CDRS_PER_MONTH, 4).

-spec summary(pqc_cb_api:state(), kz_term:ne_binary()) -> pqc_cb_api:response().
summary(API, AccountId) ->
    summary(API, AccountId, <<"application/json">>).

-spec summary(pqc_cb_api:state(), kz_term:ne_binary(), kz_term:ne_binary()) -> pqc_cb_api:response().
summary(API, AccountId, Accept) ->
    URL = cdrs_url(AccountId),
    RequestHeaders = pqc_cb_api:request_headers(API, [{<<"accept">>, Accept}]),

    Expectations = [#{'response_codes' => [200]
                     ,'response_headers' => [{"content-type", kz_term:to_list(Accept)}]
                     }
                   ,#{'response_codes' => [204]}
                   ],

    pqc_cb_api:make_request(Expectations
                           ,fun kz_http:get/2
                           ,URL
                           ,RequestHeaders
                           ).

unpaginated_summary(API, AccountId) ->
    unpaginated_summary(API, AccountId, 'true').

unpaginated_summary(API, AccountId, ShouldChunk) ->
    URL = cdrs_url(AccountId) ++ "?paginate=false" ++ should_chunk(ShouldChunk),
    RequestHeaders = pqc_cb_api:request_headers(API),

    Expectations = [#{'response_codes' => [200]}
                   ,#{'response_codes' => [204]}
                   ],

    pqc_cb_api:make_request(Expectations
                           ,fun kz_http:get/2
                           ,URL
                           ,RequestHeaders
                           ).

should_chunk('true') -> "";
should_chunk('false') -> "&is_chunked=false".

paginated_summary(API, AccountId) ->
    paginated_summary(API, AccountId, 'undefined').

-spec paginated_summary(pqc_cb_api:state(), kz_term:ne_binary(), kz_term:api_ne_binary()) ->
          {'error', binary()} |
          kz_json:objects().
paginated_summary(API, AccountId, OwnerId) ->
    URL = paginated_cdrs_url(AccountId, OwnerId, ?CDRS_PER_MONTH div 2),
    RequestHeaders = pqc_cb_api:request_headers(API, []),

    Expectations = [#{'response_codes' => [200]
                     ,'response_headers' => [{"content-type", "application/json"}]
                     }
                   ,#{'response_codes' => [204]}
                   ],

    collect_paginated_results(URL, URL, RequestHeaders, Expectations, []).

collect_paginated_results(BaseURL, URL, RequestHeaders, Expectations, Collected) ->
    case pqc_cb_api:make_request(Expectations
                                ,fun kz_http:get/2
                                ,URL
                                ,RequestHeaders
                                )
    of
        {'error', _}=E -> E;
        <<JSON/binary>> ->
            handle_paginated_results(BaseURL, RequestHeaders, Expectations, Collected, kz_json:decode(JSON))
    end.

handle_paginated_results(BaseURL, RequestHeaders, Expectations, Collected, RespJObj) ->
    Data = kz_json:get_list_value(<<"data">>, RespJObj, []),
    lager:info("adding page: ~p~n", [Data]),
    case kz_json:get_ne_binary_value(<<"next_start_key">>, RespJObj) of
        'undefined' -> Data ++ Collected;
        NextStartKey ->
            lager:info("collecting next page from ~s: ~s", [BaseURL, NextStartKey]),
            collect_paginated_results(BaseURL
                                     ,BaseURL ++ [$& | start_key(NextStartKey)]
                                     ,update_request_id(RequestHeaders)
                                     ,Expectations
                                     ,Data ++ Collected
                                     )
    end.

update_request_id(RequestHeaders) ->
    NewRequestId = case re:split(props:get_value(<<"x-request-id">>, RequestHeaders), "-") of
                       [Id, Now] -> iolist_to_binary([Id, "-", Now, "-", "1"]);
                       [Id, Now, Nth] -> iolist_to_binary([Id, "-", Now, "-", incr_nth(Nth)])
                   end,
    props:set_value(<<"x-request-id">>, kz_term:to_list(NewRequestId), RequestHeaders).

incr_nth(Nth) ->
    integer_to_list(kz_term:to_integer(Nth) + 1).

-spec fetch(pqc_cb_api:state(), kz_term:ne_binary(), kz_term:ne_binary()) -> pqc_cb_api:response().
fetch(API, AccountId, CDRId) ->
    URL = cdr_url(AccountId, CDRId),
    RequestHeaders = pqc_cb_api:request_headers(API),
    pqc_cb_api:make_request([200]
                           ,fun kz_http:get/2
                           ,URL
                           ,RequestHeaders
                           ).

-spec interactions(pqc_cb_api:state(), kz_term:ne_binary()) -> pqc_cb_api:response().
interactions(API, AccountId) ->
    URL = interactions_url(AccountId),
    RequestHeaders = pqc_cb_api:request_headers(API),
    pqc_cb_api:make_request([200]
                           ,fun kz_http:get/2
                           ,URL
                           ,RequestHeaders
                           ).

-spec paginated_interactions(pqc_cb_api:state(), kz_term:ne_binary(), kz_term:ne_binary()) -> pqc_cb_api:response().
paginated_interactions(API, AccountId, OwnerId) ->
    URL = paginated_interactions_url(AccountId, OwnerId, 2),
    RequestHeaders = pqc_cb_api:request_headers(API),
    collect_paginated_results(URL, URL, RequestHeaders, [200], []).

-spec legs(pqc_cb_api:state(), kz_term:ne_binary(), kz_term:ne_binary()) -> pqc_cb_api:response().
legs(API, AccountId, InteractionId) ->
    URL = legs_url(AccountId, InteractionId),
    RequestHeaders = pqc_cb_api:request_headers(API),
    pqc_cb_api:make_request([200]
                           ,fun kz_http:get/2
                           ,URL
                           ,RequestHeaders
                           ).

legs_url(AccountId, InteractionId) ->
    string:join([pqc_cb_accounts:account_url(AccountId), "cdrs", "legs", kz_term:to_list(InteractionId)], "/").

interactions_url(AccountId) ->
    string:join([pqc_cb_accounts:account_url(AccountId), "cdrs", "interaction"], "/").

paginated_interactions_url(AccountId, OwnerId, PageSize) ->
    string:join([pqc_cb_accounts:account_url(AccountId)
                ,"users", kz_term:to_list(OwnerId)
                ,"cdrs", "interaction"
                ]
               ,"/"
               )
        ++ "?page_size=" ++ kz_term:to_list(PageSize).

cdr_url(AccountId, CDRId) ->
    string:join([pqc_cb_accounts:account_url(AccountId), "cdrs", kz_term:to_list(CDRId)], "/").

cdrs_url(AccountId) ->
    string:join([pqc_cb_accounts:account_url(AccountId), "cdrs"], "/").

paginated_cdrs_url(AccountId, 'undefined', PageSize) ->
    string:join([pqc_cb_accounts:account_url(AccountId), "cdrs"], "/")
        ++ "?" ++ page_size(PageSize);
paginated_cdrs_url(AccountId, OwnerId, PageSize) ->
    string:join([pqc_cb_accounts:account_url(AccountId), "users", kz_term:to_list(OwnerId), "cdrs"], "/")
        ++ "?" ++ page_size(PageSize).

page_size(N) -> "page_size=" ++ kz_term:to_list(N).

start_key('undefined') -> "";
start_key(StartKey) -> "start_key=" ++ kz_term:to_list(StartKey).

-spec seq() -> 'ok'.
seq() ->
    kapps_config:set_default(<<"crossbar.cdrs">>, <<"should_filter_empty_strings">>, 'true'),
    _ = straight_seq(),
    _ = paginated_seq(),
    big_dataset_seq().

-spec straight_seq() -> 'ok'.
straight_seq() ->
    API = pqc_cb_api:init_api(['crossbar'], ['cb_cdrs']),
    AccountId = create_account(API),

    EmptySummaryResp = summary(API, AccountId),
    lager:info("empty summary resp: ~s", [EmptySummaryResp]),
    [] = kz_json:get_list_value(<<"data">>, kz_json:decode(EmptySummaryResp)),

    EmptyCSVResp = summary(API, AccountId, <<"text/csv">>),
    lager:info("empty CSV resp: ~s", [EmptyCSVResp]),

    CDRs = seed_cdrs(AccountId),
    lager:info("CDRs: ~p~n", [CDRs]),

    SummaryResp = summary(API, AccountId),
    lager:info("summary resp: ~s", [SummaryResp]),
    RespCDRs = kz_json:get_list_value(<<"data">>, kz_json:decode(SummaryResp)),
    'true' = cdrs_exist(CDRs, RespCDRs),
    lager:info("all cdrs found in response"),

    CSVResp = summary(API, AccountId, <<"text/csv">>),
    lager:info("CSV resp: ~s", [CSVResp]),

    InteractionsResp = interactions(API, AccountId),
    lager:info("interactions resp: ~s", [InteractionsResp]),

    lists:foreach(fun(CDR) -> seq_cdr(API, AccountId, CDR) end, CDRs),

    cleanup(API),
    lager:info("FINISHED STRAIGHT SEQ").

paginated_seq() ->
    API = pqc_cb_api:init_api(['crossbar'], ['cb_cdrs']),
    AccountId = create_account(API),
    OwnerId = create_owner(AccountId),

    EmptySummaryResp = paginated_summary(API, AccountId),
    lager:info("empty summary resp: ~p", [EmptySummaryResp]),
    [] = EmptySummaryResp,

    CDRs = seed_cdrs(AccountId, OwnerId),
    CDRIds = lists:sort([kz_doc:id(I) || I <- CDRs]),
    lager:info("CDRs: ~p~n", [CDRIds]),

    SummaryResp = paginated_summary(API, AccountId, OwnerId),
    lager:info("summary resp: ~p", [SummaryResp]),

    'true' = cdrs_exist(CDRs, SummaryResp),
    lager:info("all cdrs found in response"),

    InteractionsResp = paginated_interactions(API, AccountId, OwnerId),
    InteractionIds = lists:sort([kzd_cdrs:interaction_id(I) || I <- InteractionsResp]),

    CDRInteractionIDs = lists:usort([kzd_cdrs:interaction_id(CDR) || CDR <- CDRs]),
    lager:info("expected CDR interaction IDs: ~p", [CDRInteractionIDs]),
    lager:info("received interaction IDs: ~p", [InteractionIds]),
    case CDRInteractionIDs =:= InteractionIds of
        'true' -> 'ok';
        'false' ->
            lager:info("failed to fetch expected interaction IDs from API"),
            lager:info("missing from response: ~p", [CDRInteractionIDs -- InteractionIds]),
            throw({'error', 'interaction_ids', 'not_found'})
    end,

    cleanup(API),
    lager:info("FINISHED PAGINATED SEQ").

-spec big_dataset_seq() -> 'ok'.
big_dataset_seq() ->
    lager:info("creating large dataset and not paginating results"),
    API = pqc_cb_api:init_api(['crossbar'], ['cb_cdrs']),
    AccountId = create_account(API),

    {Year, Month, Day} = erlang:date(),

    CDRCount = 2600,

    CDRs = lists:foldl(fun(_, Acc) ->
                               InteractionId = interaction_id(Year, Month, Day),
                               [create_cdr(AccountId, 'undefined', Year, Month, InteractionId) | Acc]
                       end
                      ,[]
                      ,lists:seq(1,CDRCount)
                      ),

    AccountMODb = kz_util:format_account_id(AccountId, Year, Month),
    {'ok', _} = kazoo_modb:save_docs(AccountMODb, CDRs, [{'publish_change_notice', 'false'}]),

    _ = kapps_config:set_default(<<"crossbar">>, <<"request_memory_limit">>, 'null'),
    ChunkedJSON = unpaginated_summary(API, AccountId),
    ChunkedJObj = kz_json:decode(ChunkedJSON),
    ChunkedCount = length(kz_json:get_list_value(<<"data">>, ChunkedJObj)),
    lager:info("unpaginated and unbound memory resp returned ~p CDRs", [ChunkedCount]),
    CDRCount = ChunkedCount,

    UnChunkedJSON = unpaginated_summary(API, AccountId, 'false'),
    UnChunkedJObj = kz_json:decode(UnChunkedJSON),
    UnChunkedCount = length(kz_json:get_list_value(<<"data">>, UnChunkedJObj)),
    lager:info("unpaginated/unchunked and unbound memory resp returned ~p CDRs", [UnChunkedCount]),
    CDRCount = UnChunkedCount,

    _ = kapps_config:set_default(<<"crossbar">>, <<"request_memory_limit">>, 1024 * 1024 * 10), % cap at 10Mb

    ChunkedUnpaginatedJSON = unpaginated_summary(API, AccountId),
    ChunkedUnpaginatedJObj = kz_json:decode(ChunkedUnpaginatedJSON),
    ChunkedUnpaginatedCount = length(kz_json:get_list_value(<<"data">>, ChunkedUnpaginatedJObj)),
    lager:info("chunked/unpaginated and unbound memory resp returned ~p CDRs", [ChunkedUnpaginatedCount]),
    CDRCount = ChunkedUnpaginatedCount,

    _ = kapps_config:set_default(<<"crossbar">>, <<"request_memory_limit">>, 1024 * 1024 * 5), % cap at 5Mb

    {'error', UnChunkedErrorJSON} = unpaginated_summary(API, AccountId, 'false'),
    lager:info("unchunked/unpaginated and bound memory resp: ~s", [UnChunkedErrorJSON]),
    UnChunkedErrorJObj = kz_json:decode(UnChunkedErrorJSON),
    416 = kz_json:get_integer_value(<<"error">>, UnChunkedErrorJObj),
    <<"range not satisfiable">> = kz_json:get_ne_binary_value(<<"message">>, UnChunkedErrorJObj),

    _ = kapps_config:set_default(<<"crossbar">>, <<"request_memory_limit">>, 'null'),
    PaginatedSummary = paginated_summary(API, AccountId),
    lager:info("paginated: ~s", [PaginatedSummary]),

    cleanup(API),
    lager:info("FINISHED BIG DATASET SEQ").

seq_cdr(API, AccountId, CDR) ->
    CDRId = kz_doc:id(CDR),
    InteractionId = kzd_cdrs:interaction_id(CDR),

    FetchResp = fetch(API, AccountId, CDRId),
    lager:info("~s: fetch resp ~s", [CDRId, FetchResp]),
    FetchedJObj = kz_json:get_json_value(<<"data">>, kz_json:decode(FetchResp)),
    'true' = cdr_exists(CDR, [FetchedJObj]),

    %% KZOO-45: Ensure empty strings have been stripped
    'undefined' = kz_json:get_ne_binary_value(<<"media_server">>, FetchedJObj),

    %% Should be able to convert CDR ID to interaction_id
    LegsResp = legs(API, AccountId, CDRId),
    lager:info("~s: legs by id resp: ~s", [CDRId, LegsResp]),
    'true' = cdr_exists(CDR, kz_json:get_list_value(<<"data">>, kz_json:decode(LegsResp))),

    InteractionResp = legs(API, AccountId, InteractionId),
    lager:info("~s: legs by interaction resp: ~s", [CDRId, InteractionResp]),
    'true' = cdr_exists(CDR, kz_json:get_list_value(<<"data">>, kz_json:decode(InteractionResp))).

cdr_exists(CDR, RespCDRs) ->
    lists:any(fun(RespCDR) -> kz_doc:id(RespCDR) =:= kz_doc:id(CDR) end, RespCDRs).

-spec cdrs_exist(kz_json:objects(), kz_json:object()) -> boolean().
cdrs_exist([], []) -> 'true';
cdrs_exist([], APIs) ->
    IDs = [kz_doc:id(CDR) || CDR <- APIs],
    lager:info("  failed to find API results in CDRs: ~s", [kz_binary:join(IDs, <<", ">>)]),
    'false';
cdrs_exist(CDRs, []) ->
    IDs = [kz_doc:id(CDR) || CDR <- CDRs],
    lager:info("  failed to find CDR(s) in API response: ~s", [kz_binary:join(IDs, <<", ">>)]),
    'false';
cdrs_exist([_|_]=CDRs, [API|APIs]) ->
    lager:debug("filtering out ~s", [kz_doc:id(API)]),
    cdrs_exist([CDR || CDR <- CDRs, kz_doc:id(CDR) =/= kz_doc:id(API)]
              ,APIs
              ).

create_account(API) ->
    AccountResp = pqc_cb_accounts:create_account(API, hd(?ACCOUNT_NAMES)),
    lager:info("created account: ~s", [AccountResp]),

    kz_json:get_value([<<"data">>, <<"id">>], kz_json:decode(AccountResp)).

create_owner(AccountId) ->
    AccountDb = kz_util:format_account_db(AccountId),

    OwnerId = kz_binary:rand_hex(16),
    Owner = kz_json:set_value(<<"_id">>, OwnerId, kzd_users:new()),
    {'ok', _Saved}= kz_datamgr:save_doc(AccountDb, Owner),
    lager:info("saved owner to ~s: ~p", [AccountDb, _Saved]),
    OwnerId.

-spec cleanup() -> 'ok'.
cleanup() ->
    _ = pqc_cb_accounts:cleanup_accounts(?ACCOUNT_NAMES),
    _ = kapps_config:set_default(<<"crossbar">>, <<"request_memory_limit">>, 'null'),
    cleanup_system().

cleanup(API) ->
    lager:info("CLEANUP TIME, EVERYBODY HELPS"),
    _ = pqc_cb_accounts:cleanup_accounts(API, ?ACCOUNT_NAMES),
    _ = pqc_cb_api:cleanup(API),
    cleanup_system().

cleanup_system() -> 'ok'.

seed_cdrs(AccountId) ->
    seed_cdrs(AccountId, 'undefined').

seed_cdrs(AccountId, OwnerId) ->
    {Year, Month, _} = erlang:date(),
    seed_cdrs(AccountId, OwnerId, Year, Month).

seed_cdrs(AccountId, OwnerId, Year, Month) ->
    AccountMODb = kz_util:format_account_id(AccountId, Year, Month),
    _ = kazoo_modb:create(AccountMODb),

    CDRs = seed_interaction(AccountId, OwnerId, Year, Month),
    MoreCDRs = seed_interaction(AccountId, OwnerId, Year, Month),
    EvenMoreCDRs = seed_interaction(AccountId, OwnerId, Year, Month),
    {PrevY, PrevM} = kazoo_modb_util:prev_year_month(Year, Month),
    PrevCDRs = seed_interaction(AccountId, OwnerId, PrevY, PrevM),
    CDRs ++ MoreCDRs ++ EvenMoreCDRs ++ PrevCDRs.

seed_interaction(AccountId, OwnerId, Year, Month) ->
    {{_, _, Day}, _} = calendar:universal_time(),
    {Y, M, D} = kz_date:normalize({Year, Month, Day}),

    InteractionId = interaction_id(Y, M, D),

    [element(2, seed_cdr(AccountId, OwnerId, Y, M, InteractionId)) || _ <- lists:seq(1, ?CDRS_PER_MONTH)].

interaction_id(Year, Month, Day) ->
    InteractionTime = interaction_time(Year, Month, Day),
    InteractionKey = kz_binary:rand_hex(4),
    list_to_binary([integer_to_binary(InteractionTime), "-", InteractionKey]).

seed_cdr(AccountId, OwnerId, Year, Month, InteractionId) ->
    [ITime, InteractionKey] = binary:split(InteractionId, <<"-">>),
    InteractionTime = kz_term:to_integer(ITime),

    CDR = create_cdr(AccountId, OwnerId, Year, Month
                    ,InteractionId, InteractionTime, InteractionKey
                    ),

    AccountMODb = kz_util:format_account_id(AccountId, InteractionTime),
    kazoo_modb:save_doc(AccountMODb, CDR, ['allow_old_modb_creation']).

create_cdr(AccountId, OwnerId, Year, Month, InteractionId) ->
    [ITime, InteractionKey] = binary:split(InteractionId, <<"-">>),
    InteractionTime = kz_term:to_integer(ITime),
    create_cdr(AccountId, OwnerId, Year, Month, InteractionId, InteractionTime, InteractionKey).

create_cdr(AccountId, OwnerId, Year, Month, InteractionId, InteractionTime, InteractionKey) ->
    CallId = kz_binary:rand_hex(6),

    CDRId = kzd_cdrs:create_doc_id(CallId, Year, Month),

    AccountMODb = kz_util:format_account_id(AccountId, InteractionTime),

    JObj = kz_json:from_list([{<<"_id">>, CDRId}
                             ,{<<"call_id">>, CallId}

                             ,{<<"interaction_id">>, InteractionId}
                             ,{<<"interaction_key">>, InteractionKey}
                             ,{<<"interaction_time">>, InteractionTime}

                             ,{<<"custom_channel_vars">>, kz_json:from_list([{<<"owner_id">>, OwnerId}])}

                             ,{<<"call_direction">>, <<"inbound">>}

                             ,{<<"request">>, <<"2600@hertz.com">>}
                             ,{<<"to">>, <<"capt@crunch.com">>}
                             ,{<<"from">>, <<"cereal@killer.com">>}

                             ,{<<"ringing_seconds">>, 3}
                             ,{<<"billing_seconds">>, 6}
                             ,{<<"duration_seconds">>, 9}
                             ,{<<"timestamp">>, InteractionTime}
                             ]),

    Props = [{'type', <<"cdr">>}
            ,{'account_id', AccountId}
            ,{'now', InteractionTime}
            ],
    kz_doc:update_pvt_parameters(JObj, AccountMODb, Props).

interaction_time(Year, Month, Day) ->
    {Today, _} = calendar:universal_time(),
    interaction_time(Year, Month, Day, Today).

interaction_time(Year, Month, Day, {Year, Month, Day}) ->
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {0, 0, 0}});
interaction_time(Year, Month, Day, _Today) ->
    calendar:datetime_to_gregorian_seconds({{Year, Month, Day}, {23, 59, 59}}).

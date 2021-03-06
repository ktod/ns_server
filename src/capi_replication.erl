%% @author Couchbase <info@couchbase.com>
%% @copyright 2011 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%

-module(capi_replication).

-export([get_missing_revs/2, update_replicated_docs/3]).

%% those are referenced from capi.ini
-export([handle_pre_replicate/1,
         handle_commit_for_checkpoint/1,
         handle_mass_vbopaque_check/1]).

-include("xdc_replicator.hrl").
-include("mc_entry.hrl").
-include("mc_constants.hrl").

-include_lib("eunit/include/eunit.hrl").

-define(SLOW_THRESHOLD_SECONDS, 180).

%% note that usual REST call timeout is 60 seconds. So no point making it any longer
-define(XDCR_CHECKPOINT_TIMEOUT, ns_config:get_timeout_fast(xdcr_checkpoint_timeout, 60000)).


%% public functions
get_missing_revs(#db{name = DbName}, JsonDocIdRevs) ->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),
    TimeStart = now(),
    %% enumerate all keys and fetch meta data by getMeta for each of them to ep_engine
    Results =
        lists:foldr(
          fun ({Id, Rev}, Acc) ->
                  case is_missing_rev(Bucket, VBucket, Id, Rev) of
                      false ->
                          Acc;
                      true ->
                          [{Id, Rev} | Acc]
                  end;
              (_, _) ->
                  throw(unsupported)
          end, [], JsonDocIdRevs),

    NumCandidates = length(JsonDocIdRevs),
    RemoteWinners = length(Results),
    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    AvgLatency = TimeSpent div NumCandidates,
    ?xdcr_debug("[Bucket:~p, Vb:~p]: after conflict resolution for ~p docs, num of remote winners is ~p and "
                "number of local winners is ~p. (time spent in ms: ~p, avg latency in ms per doc: ~p)",
                [Bucket, VBucket, NumCandidates, RemoteWinners, (NumCandidates-RemoteWinners),
                 TimeSpent, AvgLatency]),

    %% dump error msg if timeout
    TimeSpentSecs = TimeSpent div 1000,
    case TimeSpentSecs > ?SLOW_THRESHOLD_SECONDS of
        true ->
            ?xdcr_error("[Bucket:~p, Vb:~p]: conflict resolution for ~p docs  takes too long to finish!"
                        "(total time spent: ~p secs)",
                        [Bucket, VBucket, NumCandidates, TimeSpentSecs]);
        _ ->
            ok
    end,

    {ok, Results}.

update_replicated_docs(#db{name = DbName}, Docs, Options) ->
    {Bucket, VBucket} = capi_utils:split_dbname(DbName),

    case proplists:get_value(all_or_nothing, Options, false) of
        true ->
            throw(unsupported);
        false ->
            ok
    end,

    TimeStart = now(),
    %% enumerate all docs and update them
    Errors =
        lists:foldr(
          fun (#doc{id = Id, rev = Rev} = Doc, ErrorsAcc) ->
                  case do_update_replicated_doc_loop(Bucket, VBucket, Doc) of
                      ok ->
                          ErrorsAcc;
                      {error, Error} ->
                          [{{Id, Rev}, Error} | ErrorsAcc]
                  end
          end,
          [], Docs),

    TimeSpent = timer:now_diff(now(), TimeStart) div 1000,
    AvgLatency = TimeSpent div length(Docs),

    %% dump error msg if timeout
    TimeSpentSecs = TimeSpent div 1000,
    case TimeSpentSecs > ?SLOW_THRESHOLD_SECONDS of
        true ->
            ?xdcr_error("[Bucket:~p, Vb:~p]: update ~p docs takes too long to finish!"
                        "(total time spent: ~p secs)",
                        [Bucket, VBucket, length(Docs), TimeSpentSecs]);
        _ ->
            ok
    end,

    case Errors of
        [] ->
            ?xdcr_debug("[Bucket:~p, Vb:~p]: successfully update ~p replicated mutations "
                        "(time spent in ms: ~p, avg latency per doc in ms: ~p)",
                        [Bucket, VBucket, length(Docs), TimeSpent, AvgLatency]),

            ok;
        [FirstError | _] ->
            %% for some reason we can only return one error. Thus
            %% we're logging everything else here
            ?xdcr_error("[Bucket: ~p, Vb: ~p] Error: could not update docs. Time spent in ms: ~p, "
                        "# of docs trying to update: ~p, error msg: ~n~p",
                        [Bucket, VBucket, TimeSpent, length(Docs), Errors]),
            {ok, FirstError}
    end.

%% helper functions
is_missing_rev(Bucket, VBucket, Id, RemoteMeta) ->
    case get_meta(Bucket, VBucket, Id) of
        {memcached_error, key_enoent, _CAS} ->
            true;
        {memcached_error, not_my_vbucket, _} ->
            throw({bad_request, not_my_vbucket});
        {ok, LocalMeta, _CAS} ->
             %% we do not have any information about deletedness of
             %% the remote side thus we use only revisions to
             %% determine a winner
            case max(LocalMeta, RemoteMeta) of
                %% if equal, prefer LocalMeta since in this case, no need
                %% to replicate the remote item, hence put LocalMeta before
                %% RemoteMeta.
                LocalMeta ->
                    false;
                RemoteMeta ->
                    true
            end
    end.

do_update_replicated_doc_loop(Bucket, VBucket, Doc0) ->
    Doc = #doc{id = DocId, rev = DocRev,
        body = DocValue, deleted = DocDeleted} = couch_doc:with_json_body(Doc0),
    {DocSeqNo, DocRevId} = DocRev,
    RV =
        case get_meta(Bucket, VBucket, DocId) of
            {memcached_error, key_enoent, CAS} ->
                update_locally(Bucket, DocId, VBucket, DocValue, DocRev, DocDeleted, CAS);
            {memcached_error, not_my_vbucket, _} ->
                {error, {bad_request, not_my_vbucket}};
            {ok, {OurSeqNo, OurRevId}, LocalCAS} ->
                {RemoteMeta, LocalMeta} =
                    case DocDeleted of
                        false ->
                            %% for non-del mutation, compare full metadata
                            {{DocSeqNo, DocRevId}, {OurSeqNo, OurRevId}};
                        _ ->
                            %% for deletion, just compare seqno and CAS to match
                            %% the resolution algorithm in ep_engine:deleteWithMeta
                            <<DocCAS:64, _DocExp:32, _DocFlg:32>> = DocRevId,
                            <<OurCAS:64, _OurExp:32, _OurFlg:32>> = OurRevId,
                            {{DocSeqNo, DocCAS}, {OurSeqNo, OurCAS}}
                    end,
                case max(LocalMeta, RemoteMeta) of
                    %% if equal, prefer LocalMeta since in this case, no need
                    %% to replicate the remote item, hence put LocalMeta before
                    %% RemoteMeta.
                    LocalMeta ->
                        ok;
                    %% if remoteMeta wins, need to persist the remote item, using
                    %% the same CAS returned from the get_meta() above.
                    RemoteMeta ->
                        update_locally(Bucket, DocId, VBucket, DocValue, DocRev, DocDeleted, LocalCAS)
                end
        end,

    case RV of
        retry ->
            do_update_replicated_doc_loop(Bucket, VBucket, Doc);
        _Other ->
            RV
    end.

update_locally(Bucket, DocId, VBucket, Value, Rev, DocDeleted, LocalCAS) ->
    case ns_memcached:update_with_rev(Bucket, VBucket, DocId, Value, Rev, DocDeleted, LocalCAS) of
        {ok, _, _} ->
            ok;
        {memcached_error, key_enoent, _} ->
            retry;
        {memcached_error, key_eexists, _} ->
            retry;
        {memcached_error, not_my_vbucket, _} ->
            {error, {bad_request, not_my_vbucket}};
        {memcached_error, einval, _} ->
            {error, {bad_request, einval}}
    end.


get_meta(Bucket, VBucket, DocId) ->
    case ns_memcached:get_meta(Bucket, DocId, VBucket) of
        {ok, Rev, CAS, _MetaFlags} ->
            {ok, Rev, CAS};
        Other ->
            Other
    end.

extract_base_ck_params(Req) ->
    couch_httpd:validate_ctype(Req, "application/json"),
    {Obj} = couch_httpd:json_body_obj(Req),
    Bucket =
        case proplists:get_value(<<"bucket">>, Obj) of
            undefined ->
                undefined;
            B ->
                %% pre 3.0 clusters will send us "dbname+uuid" here
                %% so parse uuid out
                {B1, undefined, _} = capi_utils:split_dbname_with_uuid(B),
                B1
        end,

    BucketUUID = proplists:get_value(<<"bucketUUID">>, Obj),
    case (Bucket =:= undefined
          orelse BucketUUID =:= undefined) of
        true ->
            erlang:throw(bad_request);
        _ -> true
    end,
    BucketConfig = capi_frontend:verify_bucket_auth(Req, Bucket),

    case proplists:get_value(uuid, BucketConfig) =:= BucketUUID of
        true ->
            ok;
        false ->
            erlang:throw({not_found, uuid_mismatch})
    end,

    {Obj, Bucket}.

extract_ck_params(Req) ->
    {Body, Bucket} = extract_base_ck_params(Req),

    VB = proplists:get_value(<<"vb">>, Body),
    case VB =:= undefined of
        true ->
            erlang:throw(bad_request);
        _ -> true
    end,

    VBOpaque = proplists:get_value(<<"vbopaque">>, Body),

    CommitOpaque = proplists:get_value(<<"commitopaque">>, Body),

    {Bucket, VB, VBOpaque, CommitOpaque}.

handle_pre_replicate(Req) ->
    {Bucket, VB, VBOpaque, CommitOpaque} = extract_ck_params(Req),

    FailoverLog = case xdcr_dcp_streamer:get_failover_log(binary_to_list(Bucket), VB) of
                      {memcached_error, not_my_vbucket} ->
                          erlang:throw({not_found, not_my_vbucket});
                      XFailoverLog when is_list(XFailoverLog) ->
                          XFailoverLog
                  end,

    {VBUUID, _} = lists:last(FailoverLog),

    {CommitUUID, CommitSeq} = case CommitOpaque of
                                  [XU, XS] -> {XU, XS};
                                  _ -> {undefined, -1}
                              end,

    CommitOk = case CommitOpaque =:= undefined of
                   true -> true;
                   _ ->
                       validate_commit(FailoverLog, CommitUUID, CommitSeq)
               end,

    VBMatches = VBOpaque =:= undefined orelse VBOpaque =:= VBUUID,

    ?xdcr_debug("CommitOk: ~p, VBMatches: ~p, CommitOpaque: ~p, stuff: ~p",
                [CommitOk, VBMatches,
                 CommitOpaque, {FailoverLog, CommitUUID, CommitSeq}]),

    Code = case VBMatches andalso CommitOk of
               true -> 200;
               false -> 400
           end,

    couch_httpd:send_json(Req, Code, {[{<<"vbopaque">>, VBUUID}]}).

handle_mass_vbopaque_check(Req) ->
    {Body, Bucket} = extract_base_ck_params(Req),

    Opaques0 = proplists:get_value(<<"vbopaques">>, Body),
    Opaques =
        case is_list(Opaques0) of
            true ->
                Opaques0;
            _ ->
                undefined
        end,
    case Opaques =:= undefined of
        true ->
            erlang:throw(bad_request);
        _ -> true
    end,

    Keys0 = [{iolist_to_binary(io_lib:format("vb_~B:uuid", [Vb])), Vb, VO}
             || [Vb, VO] <- Opaques],
    Keys = lists:sort(Keys0),

    KV0 = ns_memcached:get_seqno_stats(Bucket, undefined),
    KV = lists:sort([{K, V} || {K, V} <- KV0,
                               is_uuid_stat_key(K)]),

    {Matched, Mismatched, Missing} = mass_vbopaque_check_loop(Keys, KV, [], [], []),

    couch_httpd:send_json(Req, 200, {[{<<"matched">>, Matched},
                                      {<<"mismatched">>, [[V, O] || {V, O} <- Mismatched]},
                                      {<<"missing">>, Missing}]}).

is_uuid_stat_key(K) when size(K) < 5 ->
    false;
is_uuid_stat_key(K) ->
    PrefixSize = size(K)-5,
    case K of
        <<_:PrefixSize/binary, ":uuid">> ->
            true;
        _ ->
            false
    end.

is_uuid_stat_key_test() ->
    true = is_uuid_stat_key(<<"vb_5:uuid">>),
    false = is_uuid_stat_key(<<"vb_5:seqno">>),
    false = is_uuid_stat_key(<<>>),
    false = is_uuid_stat_key(<<"a">>).

mass_vbopaque_check_loop([{K1, Vb, VO} | RestExpected] = Expected,
                         [{K2, Value} | RestStats] = Stats,
                         AccMatch, AccMismatch, AccMissing) ->
    if
        K1 > K2 ->
            mass_vbopaque_check_loop(Expected, RestStats,
                                     AccMatch, AccMismatch, AccMissing);
        K1 =:= K2 ->
            RealVO = list_to_integer(binary_to_list(Value)),
            case VO =:= RealVO of
                true ->
                    mass_vbopaque_check_loop(RestExpected, RestStats,
                                             [Vb | AccMatch], AccMismatch, AccMissing);
                false ->
                    mass_vbopaque_check_loop(RestExpected, RestStats,
                                             AccMatch, [{Vb, RealVO} | AccMismatch], AccMissing)
            end;
        true ->
            mass_vbopaque_check_loop(RestExpected, Stats,
                                     AccMatch, AccMismatch, [Vb | AccMissing])
    end;
mass_vbopaque_check_loop([] = _Expected, _Stats, AccMatch, AccMismatch, AccMissing) ->
    {AccMatch, AccMismatch, AccMissing};
mass_vbopaque_check_loop([{_, Vb, _} | RestExpected], [] = _Stats, AccMatch, AccMismatch, AccMissing) ->
    mass_vbopaque_check_loop(RestExpected, [], AccMatch, AccMismatch, [Vb | AccMissing]).

mass_vbopaque_check_loop_test() ->
    Expected = [{100, 0, 0},
                {110, 1, 21},
                {120, 2, 3},
                {130, 3, 4}],
    Stats = [{110, <<"21">>},
             {115, <<"a">>},
             {120, <<"33">>}],
    {[1, a], [{2, 33}, b], [3, 0, c]} = mass_vbopaque_check_loop(Expected, Stats, [a], [b], [c]).

get_vbucket_seqno_stats(BucketName, Vb) ->
    KV = ns_memcached:get_seqno_stats(BucketName, Vb),
    Key = iolist_to_binary(io_lib:format("vb_~B:uuid", [Vb])),
    SeqnoKey = iolist_to_binary(io_lib:format("vb_~B:high_seqno", [Vb])),
    U0 = misc:expect_prop_value(Key, KV),
    S0 = misc:expect_prop_value(SeqnoKey, KV),
    {list_to_integer(binary_to_list(U0)),
     list_to_integer(binary_to_list(S0))}.

handle_commit_for_checkpoint(#httpd{method='POST'}=Req) ->
    {Bucket, VB, VBOpaque, _} = extract_ck_params(Req),

    case ns_config:read_key_fast(xdcr_commits_dont_wait_disk, false) of
        true ->
            ok;
        false ->
            do_checkpoint_commit(Bucket, VB)
    end,

    {UUID, Seqno} = get_vbucket_seqno_stats(Bucket, VB),

    ?xdcr_debug("UUID: ~p, VBOpaque: ~p", [{UUID, Seqno}, VBOpaque]),

    case UUID =:= VBOpaque of
        true ->
            system_stats_collector:increment_counter(xdcr_checkpoint_commit_oks, 1),
            CommitOpaque = [UUID, Seqno],
            couch_httpd:send_json(Req, 200, {[{<<"commitopaque">>, CommitOpaque}]});
        _ ->
            system_stats_collector:increment_counter(xdcr_checkpoint_commit_mismatches, 1),
            couch_httpd:send_json(Req, 400, {[{<<"vbopaque">>, UUID}]})
    end.

do_checkpoint_commit(Bucket, VB) ->
    TimeBefore = erlang:now(),
    system_stats_collector:increment_counter(xdcr_checkpoint_commits_enters, 1),
    try
        case ns_memcached:perform_checkpoint_commit_for_xdcr(Bucket, VB, ?XDCR_CHECKPOINT_TIMEOUT) of
            ok -> ok;
            {memcached_error, not_my_vbucket} ->
                erlang:throw({not_found, not_my_vbucket})
        end
    after
        system_stats_collector:increment_counter(xdcr_checkpoint_commits_leaves, 1)
    end,

    TimeAfter = erlang:now(),
    system_stats_collector:add_histo(xdcr_checkpoint_commit_time, timer:now_diff(TimeAfter, TimeBefore)).

validate_commit(FailoverLog, CommitUUID, CommitSeq) ->
    {FailoverUUIDs, FailoverSeqs} = lists:unzip(FailoverLog),

    [SeqnosStart | FailoverSeqs1] = FailoverSeqs,

    %% validness failover log is where each uuid entry has seqno where
    %% it _ends_ rather than where it begins. It makes validness
    %% checking simpler
    ValidnessFailoverLog = lists:zip(FailoverUUIDs, FailoverSeqs1 ++ [16#ffffffffffffffff]),

    case SeqnosStart > CommitSeq of
        true -> false;
        _ ->
            lists:any(fun ({U, EndSeq}) ->
                              U =:= CommitUUID andalso CommitSeq =< EndSeq
                      end, ValidnessFailoverLog)
    end.

validate_commit_test() ->
    FailoverLog = [{13685158163256569856, 0},
                   {4598340681889701145, 48}],
    CommitUUID = 13685158163256569445,
    CommitSeq = 27,
    true = not validate_commit(FailoverLog, CommitUUID, CommitSeq),
    true = validate_commit(FailoverLog, 13685158163256569856, CommitSeq).

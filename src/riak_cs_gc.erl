%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

%% @doc Utility module for garbage collection of files.

-module(riak_cs_gc).

-include("riak_moss.hrl").
-ifdef(TEST).
-compile(export_all).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% export Public API
-export([delete_tombstone_time/0,
         gc_interval/0,
         gc_retry_interval/0,
         gc_manifests/6,
         move_manifests_to_gc_bucket/2,
         timestamp/0]).

%%%===================================================================
%%% Public API
%%%===================================================================

-spec gc_manifests(binary(), binary(), [lfs_manifest()], [binary()],
    riakc_obj:riakc_obj(), pid()) ->
    ok | {error, term()}.
gc_manifests(Bucket, Key, Manifests, UUIDsToGc, RiakObject, RiakcPid) ->
    MarkedAsPendingDelete =
    riak_moss_manifest:mark_pending_delete(Manifests, UUIDsToGc),

    NewRiakObject = riakc_obj:update_value(RiakObject,
        term_to_binary(MarkedAsPendingDelete)),

    riakc_pb_socket:put(RiakcPid, NewRiakObject),

    case move_manifests_to_gc_bucket(Manifests, RiakcPid) of
        ok ->
            case riak_moss_utils:get_manifests(RiakcPid, Bucket, Key) of
                {ok, RiakObjectAfterPD, NewManifests} ->
                    MarkedAsScheduledDelete =
                    riak_moss_manifest:mark_scheduled_delete(NewManifests,
                        UUIDsToGc),
                    NewNewRiakObject = riakc_obj:update_value(RiakObjectAfterPD,
                        term_to_binary(MarkedAsScheduledDelete)),
                    riakc_pb_socket:put(RiakcPid, NewNewRiakObject),
                    ok;
                {error, notfound}=Error ->
                    Error
            end;
        Error1 ->
            Error1
    end.

%% @doc Return the minimum number of seconds a file manifest waits in
%% the `deleted' state before being removed from the file record.
-spec delete_tombstone_time() -> non_neg_integer().
delete_tombstone_time() ->
    case application:get_env(riak_moss, delete_tombstone_time) of
        undefined ->
            ?DEFAULT_DELETE_TOMBSTONE_TIME;
        {ok, TombstoneTime} ->
            TombstoneTime
    end.

%% @doc Return the number of seconds to wait after finishing garbage
%% collection of a set of files before starting the next.
-spec gc_interval() -> non_neg_integer().
gc_interval() ->
    case application:get_env(riak_moss, gc_interval) of
        undefined ->
            ?DEFAULT_GC_INTERVAL;
        {ok, Interval} ->
            Interval
    end.

%% @doc Return the number of seconds to wait before rescheduling a
%% `pending_delete' manifest for garbage collection.
-spec gc_retry_interval() -> non_neg_integer().
gc_retry_interval() ->
    case application:get_env(riak_moss, gc_retry_interval) of
        undefined ->
            ?DEFAULT_GC_RETRY_INTERVAL;
        {ok, RetryInterval} ->
            RetryInterval
    end.

%% @doc Generate a key for storing a set of manifests for deletion.
-spec timestamp() -> non_neg_integer().
timestamp() ->
    %% TODO:
    %% could this be os:timestamp,
    %% which doesn't have a lock around it?
    riak_moss_utils:timestamp(erlang:now()).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc Copy data for a list of manifests to the
%% `riak-cs-gc' bucket to schedule them for deletion.
-spec move_manifests_to_gc_bucket([lfs_manifest()], pid()) -> ok | {error, term()}.
move_manifests_to_gc_bucket(Manifests, RiakPid) ->
    %% TODO:
    %% we should be reading the key first
    %% before writing it

    %% Create a set from the list of manifests
    ManifestSet = build_manifest_set(twop_set:new(), Manifests),
    _ = lager:debug("Manifests scheduled for deletion: ~p", [ManifestSet]),
    %% Write the set to a timestamped key in the `riak-cs-gc' bucket
    Key = generate_key(),
    RiakObject = riakc_obj:new(?GC_BUCKET, Key, term_to_binary(ManifestSet)),
    riakc_pb_socket:put(RiakPid, RiakObject).

-spec build_manifest_set(twop_set:twop_set(), [lfs_manifest()]) -> twop_set:twop_set().
build_manifest_set(Set, []) ->
    Set;
build_manifest_set(Set, [HeadManifest | RestManifests]) ->
    UpdSet = twop_set:add_element(HeadManifest, Set),
    build_manifest_set(UpdSet, RestManifests).

%% @doc Generate a key for storing a set of manifests in the
%% garbage collection bucket.
-spec generate_key() -> binary().
generate_key() ->
    list_to_binary(
      integer_to_list(
        timestamp() + leeway_seconds())).

%% @doc Return the minimum number of seconds a file manifest waits in
%% the `scheduled_delete' state before being garbage collected.
-spec leeway_seconds() -> non_neg_integer().
leeway_seconds() ->
    case application:get_env(riak_moss, leeway_seconds) of
        undefined ->
            ?DEFAULT_LEEWAY_SECONDS;
        {ok, LeewaySeconds} ->
            LeewaySeconds
    end.

%% ===================================================================
%% EUnit tests
%% ===================================================================
-ifdef(TEST).

-endif.

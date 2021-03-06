%%%-------------------------------------------------------------------
%%% @author tihon
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%% Stores ets with timestamps of every build. If build become too
%%% frequently - return false on check package. After this build can
%%% be saved with postpone_build/2 to sqlite. Every ?TASK_CHECK_INTERVAL
%%% checks sqlite for postponed builds and run them.
%%% Groups same postponed builds to one.
%%% @end
%%% Created : 04. Jun 2017 18:57
%%%-------------------------------------------------------------------
-module(oc_namespace_limiter).
-author("tihon").

-behaviour(gen_server).

-include("oc_database.hrl").

%% API
-export([start_link/0, check_package/1, postpone_build/3]).

%% gen_server callbacks
-export([init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3]).

-define(SERVER, ?MODULE).
-define(ETS, namespace_storage).
-define(CLEAN_INTERVAL, 900000).  %15 min
-define(TASK_CHECK_INTERVAL, 1000).  % 1 sec

-record(state, {sqlite_db :: pid()}).

%%%===================================================================
%%% API
%%%===================================================================
%% Remember build time.
%% If build exceeds limit per minute - return false
-spec check_package(binary()) -> boolean().
check_package(FullName) ->
  Now = oc_utils:now_to_timestamp(),
  case ets:lookup(?ETS, FullName) of
    [] ->
      ets:insert(?ETS, {FullName, Now}),
      true;
    [{_, LastBuildTS}] ->
      {ok, Limit} = application:get_env(octoenot, delay_between_build),
      LimitMilliseconds = Limit * 60000,
      case Now > LastBuildTS + LimitMilliseconds of
        true ->
          ets:insert(?ETS, {FullName, Now}),
          true;
        false -> false
      end
  end.

-spec postpone_build(binary(), binary(), binary()) -> ok.
postpone_build(Name, Url, Tag) ->
  oc_logger:info("Building ~p postponed", [Name]),
  gen_server:call(?MODULE, {postpone, Name, Url, Tag}),
  ok.

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @end
%%--------------------------------------------------------------------
-spec(start_link() ->
  {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
  ets:new(?ETS, [named_table, {read_concurrency, true}, public]),
  erlang:send_after(?CLEAN_INTERVAL, self(), clean),
  erlang:send_after(?TASK_CHECK_INTERVAL, self(), check),
  {ok, Pid} = oc_sqlite_mngr:connect(?TASKS_STORAGE),
  {ok, #state{sqlite_db = Pid}}.

handle_call({postpone, Name, Url, Tag}, _From, State = #state{sqlite_db = Db}) ->
  Res = oc_sqlite_mngr:add_task(Db, Name, Url, Tag),
  {reply, Res, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast(_Request, State) ->
  {noreply, State}.

handle_info(check, State = #state{sqlite_db = Db}) ->
  All = oc_sqlite_mngr:get_all_tasks(Db),
  lists:foreach(fun(Task) -> restart_task(Db, Task) end, unique_rows(All)),
  erlang:send_after(?TASK_CHECK_INTERVAL, self(), check),
  {noreply, State};
handle_info(clean, State) ->
  ets:delete_all_objects(?ETS),
  erlang:send_after(?CLEAN_INTERVAL, self(), clean),
  {noreply, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%% @private
restart_task(Db, {Name, Url, Tag}) ->
  Now = oc_utils:now_to_timestamp(),
  ets:insert(?ETS, {Name, Now}),
  ok = oc_loader_mngr:add_package(Name, Url, Tag),
  true = oc_sqlite_mngr:del_task(Db, Name).

%% @private
unique_rows(All) ->
  Rows = proplists:get_value(rows, All, []),
  sets:to_list(sets:from_list(Rows)).
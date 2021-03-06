%%%-------------------------------------------------------------------
%%% @author tihon
%%% @copyright (C) 2017, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 18. Jun 2017 18:03
%%%-------------------------------------------------------------------
-module(oc_erlang_mngr).
-author("tihon").

-define(GET_KERL_CMD(P),
  "curl -o" ++ P ++ " -O https://raw.githubusercontent.com/kerl/kerl/master/kerl").

%% API
-export([init/0,
  erlang_version/0,
  ensure_kerl/0,
  kerl_installations/1]).

%% check Erlang installed
%% check kerl installed
-spec init() -> {ok, string()} | error.
init() ->
  Vsn = erlang_version(),
  oc_logger:info("System Erlang vsn ~s", [Vsn]),
  {ok, Executable} = ensure_kerl("kerl"),
  {ok, Installations} = kerl_installations(Executable),
  ok = check_default_erlang(Vsn, Installations),
  ok.

%% Get default's Erlang version
-spec erlang_version() -> string().
erlang_version() ->
  erlang:system_info(otp_release).

%% Search kerl installed in system. If not - download it to priv.
-spec ensure_kerl() -> {ok, string()} | error.
ensure_kerl() ->
  ensure_kerl("kerl").

-spec kerl_installations(string()) -> {ok, list({string(), string()})} | error.
kerl_installations(Executable) ->
  Res = oc_utils:exec(Executable ++ " list installations", [sync, stdout, stderr]),
  case Res of
    {error, Err} ->
      Status = proplists:get_value(exit_status, Err),
      StdErr = proplists:get_value(stderr, Err),
      oc_logger:err(Executable ++ " calling error(~p): ~p", [Status, StdErr]),
      error;
    {ok, Reply} ->
      Installations = proplists:get_value(stdout, Reply),
      oc_logger:info("Kerl installations:~n~s", [Installations]),
      {ok, parse_installations(Installations)}
  end.


%% @private
check_default_erlang(System, Installations) ->
  {ok, Erl} = application:get_env(octoenot, default_erlang),
  case proplists:get_value(Erl, Installations) of
    undefined when System /= Erl -> % no default erlang in kerl installation and in system
      error; % TODO should install it via kerl
    _ -> ok
  end.

%% @private
%% Check kerl installed in system. If not - check in priv dir. If not - download there.
-spec ensure_kerl(string()) -> {ok, string()} | error.
ensure_kerl(Kerl) when is_list(Kerl) ->  % check kerl clause
  case kerl_version(Kerl) of
    ok -> {ok, Kerl};
    error when Kerl == "kerl" ->  % kerl checking. Call to check priv.
      ensure_kerl(undefined);
    error ->  % priv check - no more guessess, return error
      error
  end;
ensure_kerl(undefined) ->  % install kerl clause
  Pwd = oc_utils:get_priv_dir(),
  KerlPwd = filename:join([Pwd, "kerl"]),
  case ensure_kerl(KerlPwd) of
    error -> install_kerl(KerlPwd);
    Success -> Success
  end.

%% @private
install_kerl(KerlPwd) ->
  Res = oc_utils:exec(?GET_KERL_CMD(KerlPwd), [sync, stdout, stderr]),
  case Res of
    {ok, _} ->
      os:cmd("chmod +x " ++ KerlPwd),
      Return = kerl_version(KerlPwd),
      {Return, KerlPwd};
    {error, Err} ->
      Status = proplists:get_value(exit_status, Err),
      StdErr = proplists:get_value(stderr, Err),
      oc_logger:err("Can't get kerl (~p): ~p", [Status, StdErr]),
      error
  end.

%% @private
kerl_version(Kerl) ->
  Res = oc_utils:exec(Kerl ++ " version", [sync, stdout, stderr]),
  case Res of
    {error, _} -> error;
    {ok, Reply} ->
      [Vsn] = proplists:get_value(stdout, Reply),
      oc_logger:info("Kerl vsn ~s", [Vsn]),
      ok
  end.

%% @private
parse_installations(Installations) ->
  lists:foldl(
    fun(Installation, Acc) ->
      Different = binary:split(Installation, <<"\n">>, [global, trim_all]),
      Prepared = lists:map(fun split_installation/1, Different),
      Prepared ++ Acc
    end, [], Installations).

%% @private
split_installation(Installation) ->
  [Vsn, Path] = binary:split(Installation, <<" ">>),
  [AbsVsn | _] = binary:split(Vsn, <<".">>),
  {binary_to_list(AbsVsn), binary_to_list(Path)}.

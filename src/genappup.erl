-module(genappup).
-export([main/1]).
-record(mdl,{name="noname",exp=[],vsn=no_version, behavior}).

-define(DBG(X), io:format("DBG:  ~p:~p := ~p~n",[?MODULE,?LINE, X]) ).

main([BranchName]) ->
    main(BranchName, []);
main(["-c", BranchName]) ->
    main(BranchName, [{check, true}]);
main(_) ->
    io:format("usage:~n     ./genappup [options] BranchName~n"
              "               where options are:~n"
              "                 -c -- Check if app version changed~n").

main(BranchName, Opts) ->
    check_if_dirty(),
    ChangedFiles = os:cmd("git diff-index --name-status "++BranchName++" src/"),
    Lines = [parse_line(X) || X <-   string:tokens(ChangedFiles,[10,13])],
    ErlFiles = lists:filter(fun({_Action,Path}) -> lists:suffix(".erl",Path)  end,Lines),
    prepare_appup(ErlFiles, BranchName, Opts).



prepare_appup([], BranchName, _Opts) ->
    bye("HEAD and ~p does not have any differencies. Stop.~n", [BranchName]);

prepare_appup(ErlFiles, BranchName, Opts) -> 
    ApplicationFile = case appcfg:find() of
        {error, Reason} ->
            bye(reason_desc(Reason));
        {ok, X} -> X
    end,
    
    OldApp = appcfg:read(ApplicationFile,BranchName),
    CurrentApp = appcfg:read(ApplicationFile,"HEAD"),
    
    OldVSN = appcfg:get_version(OldApp),
    CurrentVSN = appcfg:get_version(CurrentApp),
    
    CheckResult = appcfg:check(OldVSN, CurrentVSN),

    Vsn = case proplists:get_value(check, Opts, false) of
        true ->
            return_check_result(CheckResult);
        false ->
            version_by_check_result(CheckResult)
    end,
    
    case Vsn of
        CurrentVSN -> ok;
        _ -> appcfg:put_version(ApplicationFile,CurrentApp,Vsn)
    end,
    
    NewFiles     =  [ gen_instruction({add,X},BranchName)      || {add,X}      <- ErlFiles],
    RemovedFiles =  [ gen_instruction({deleted,X},BranchName)  || {deleted,X}  <- ErlFiles],
    UpdatedFiles =  [ gen_instruction({modified,X},BranchName) || {modified,X} <- ErlFiles],
    
    {NewUp,NewDown} = separate_instructions(NewFiles),
    {UpdUp,UpdDoown} = separate_instructions(UpdatedFiles),
    {RemUp,RemDown} = separate_instructions(RemovedFiles),
    
    UpInstructions = NewUp ++ UpdUp ++ RemUp,
    DownInstructions = lists:reverse(RemDown) ++ UpdDoown ++ lists:reverse(NewDown),
    
    AppUp = appup_to_str(Vsn,OldVSN,UpInstructions,DownInstructions),
    save_new_appup(appcfg:get_name(CurrentApp),AppUp).

separate_instructions(Instructions) ->
    UpgI = lists:flatten([X || {X,_} <- Instructions]),
    DowngI = lists:flatten([Y|| {_,Y} <- Instructions]),
    {UpgI,DowngI}.


parse_line([$M,9|Rest]) -> {modified,Rest};
parse_line([$A,9|Rest]) -> {add,Rest};
parse_line([$D,9|Rest]) -> {deleted,Rest};
parse_line(Garbage) -> {garbage,Garbage}.

-spec gen_instruction({Command::atom(),Param::string()},Branch::string()) ->  { [ term() ], [term() ] }.
%% returns list of upgrade instructions and list of downgrade instructions

gen_instruction({add,Path},_) -> 
    Mod = ld_module("HEAD",Path),
    { [{add_module, Mod#mdl.name}], [{delete_module,Mod#mdl.name}] };
gen_instruction({modified,Path},Branch) -> 
    Mod = ld_module("HEAD",Path),
    case Mod#mdl.behavior of
        supervisor -> 
            BaseUp = [
                {update, Mod#mdl.name, supervisor},
                {comment, 
                    io_lib:format("{apply, {supervisor, restart_child, [~s, your_gen_server]}}",[Mod#mdl.name])}
            ], 
            BaseDown = [ 
                {comment,
                    io_lib:format("{apply, {supervisor, terminate_child, [~s, your_gen_server]}}",[Mod#mdl.name])},
                {comment,
                    io_lib:format("{apply, {supervisor, delete_child, [~s, your_gen_server]}}",[Mod#mdl.name])},
                {update, Mod#mdl.name, supervisor}],
            case has_export(Mod,{sup_upgrade_notify,2}) of
                true -> 
                    ModOld = ld_module(Branch,Path),
                    Oldvsn = ModOld#mdl.vsn,
                    Newvsn = Mod#mdl.vsn,
                    NotifyUp =  [{apply, {Mod#mdl.name, sup_upgrade_notify, [Oldvsn, Newvsn]}}],
                    NotifyDown = [{apply, {Mod#mdl.name, sup_upgrade_notify, [Newvsn,Oldvsn]}}];
                false -> 
                    NotifyUp = [],
                    NotifyDown = []
            end, %% has export sup_upgrade_notify
            {BaseUp++NotifyUp, NotifyDown++BaseDown };
        _ -> case has_export(Mod,{code_change,3}) of
                true -> { [{update, Mod#mdl.name , {advanced, []}}],
                          [{update, Mod#mdl.name , {advanced, []}}]}; 
                false ->  { [{load_module, Mod#mdl.name}], [{load_module, Mod#mdl.name}]}
            end %% has export  code_change
    end; %% behaviour
gen_instruction({deleted,Path},Branch) -> 
    Mod = ld_module(Branch,Path),
    { [{delete_module,Mod#mdl.name}],[{add_module, Mod#mdl.name}]};
gen_instruction(D,_)  -> D.


ld_module(Br,Path) ->
    GitCmd = lists:concat(["git show ",Br,":" ,Path]),
    ModSrc = os:cmd(GitCmd),
    {ok,Scanned,_} = erl_scan:string(ModSrc),
    {ok,Mdl} = parse(Scanned),
    Mdl.


parse(X)                    -> parse(X,[],#mdl{}).
parse([],[],M)              -> {ok,M};
parse([{dot,X}|Rest],Acc,M) ->
    Form = lists:reverse([{dot,X}|Acc]),
    NewM = extract_info(catch erl_parse:parse_form(Form),M),
    parse(Rest,[],NewM);
parse([X|Rest],Acc,M)       -> parse(Rest,[X|Acc],M).

extract_info({ok,{attribute,_,vsn,Vsn}},M)     -> M#mdl{vsn=Vsn};
extract_info({ok,{attribute,_,module,Name}},M) -> M#mdl{name=Name};
extract_info({ok,{attribute,_,export,EList}},M)-> M#mdl{exp = M#mdl.exp ++ EList};
extract_info({ok,{attribute,_,behavior,Bh}},M) -> M#mdl{behavior=Bh};
extract_info({ok,{attribute,_,behaviour,Bh}},M)-> M#mdl{behavior=Bh};
extract_info(_,M) -> %% just skip unknown constructions 
    M.

has_export(#mdl{exp=Export},ToFind) ->
    lists:member(ToFind,Export).


appup_to_str(NewVsn,OldVsn,UpInstr,DownInstr) ->
    CommaCRLF = io_lib:format(",~n",[]),
    UpStr = string:join([ case I of 
			      {comment,X} -> "    %% "++X; 
			      _ -> io_lib:format("     ~p",[I])
			  end || I <- UpInstr ],CommaCRLF),
    
    DownStr = string:join([ case D of 
				{comment,X} -> "    %% "++X; 
				_ -> io_lib:format("     ~p",[D])
			    end || D <- DownInstr ],CommaCRLF),
    
    io_lib:format("{~p,~n  [{~p,[~n~s~n    ]}],~n  [{~p,[~n~s~n    ]}]~n}.~n",[NewVsn,OldVsn,UpStr,OldVsn,DownStr]).


                
save_new_appup(App,AppUpStr) ->
    FileName = filename:join(["src",atom_to_list(App)++".appup.src"]),
    ?DBG(FileName),
    case filelib:is_file(FileName) of
        false -> file:write_file(FileName, AppUpStr);
        true -> 
            io:fwrite("File ~s already exists.~n",[FileName]),
            case ask_decision()  of
                cancel    -> io:format("~nCanceled~n");
                overwrite -> file:write_file(FileName,AppUpStr), io:format("Overwritten~n");
                save      ->
                    SaveFileName = save_filename(FileName),
                    file:write_file(SaveFileName, AppUpStr),
                    io:format("Generated appup is saved to ~s. Use your favorite merge tool.", [SaveFileName])
            end %%  decision cancel/merge/overwrite
    end. %% file already exists

save_filename(FileName) ->
    save_filename(FileName, 1).

save_filename(FileName, N) ->
    NewFileName = FileName ++ "." ++ integer_to_list(N),
    case filelib:is_file(NewFileName) of
        false -> NewFileName;
        true -> save_filename(FileName, N + 1)
    end.

-spec ask_decision() -> cancel|overwrite|save.
ask_decision() ->
   Answer =  io:get_line("C) cancel S) save alongside O) overwrite >"),
   CleanAnswer = re:replace(Answer, "(^\\s+)|(\\s+$)", "", [global,{return,list}]),
   parse_decision(CleanAnswer).


parse_decision("O")  -> overwrite;
parse_decision("o")  -> overwrite;
parse_decision("S")  -> save;
parse_decision("s")  -> save;
parse_decision("C")  -> cancel;
parse_decision("c")  -> cancel;
parse_decision(eof)  -> cancel;
parse_decision(NotExpected) -> 
    io:fwrite("Do not understand ~s~n",[NotExpected]), 
    ask_decision().

check_if_dirty() ->
    ChangedFiles = os:cmd("git diff --name-status HEAD --"),
    Lines = [parse_line(X) || X <-   string:tokens(ChangedFiles,[10,13])],
    case Lines of 
        [] -> ok;  %% no uncommited changes
        _ -> bye("there are some uncommited changes: ~n~p~nPlease commit first", [Lines], 2)
    end.

version_by_check_result({error, {bump_version, Vsn0}}) ->
    case yesno([reason_desc({bump_version, Vsn0}),
                " (", Vsn0 ,"). Should I bump up current app version?"]) of
        yes  -> 
            Vsn =  bump:version(Vsn0),
            io:format("New app vsn = ~p~n",[Vsn]),
            Vsn;
        _ -> 
            bye("Ok, stop.")
    end;
version_by_check_result({error, Reason}) ->
    bye(reason_desc(Reason));
version_by_check_result({ok, X}) -> X.

return_check_result({ok, _Vsn}) ->
    bye("OK");
return_check_result({error, Reason}) ->
    bye("~s~n", [reason_desc(Reason)], 1).

yesno(Msg) ->
    io:format("~s~n", [lists:concat(Msg)]),
    Answer = io:get_line("YN>"),
    ClearAnswer = re:replace(Answer, "(^\\s+)|(\\s+$)", "", [global,{return,list}]),
    case ClearAnswer of
        "Y" -> yes;
        "y" -> yes;
        "n" -> no;
        "N" -> no;
        _ -> 
            io:format("Please answer Y or N~n"), yesno(Msg)
    end. 

reason_desc(no_old_vsn) -> "app vsn in the branch is undefined. Cannot continue";
reason_desc(no_new_vsn) -> "app vsn in the HEAD is undefined. Cannot continue";
reason_desc(git_as_old_vsn) -> "Sorry, cannot handle git as old application version";
reason_desc(git_as_new_vsn) -> "Sorry, cannot handle git as new application version";
reason_desc({bump_version, _OldVsn}) ->
    "Despite of the fact some erlang files are changed, current and old versions are the same";
reason_desc(no_app_file) -> "No src/...app.src file. Cannot read application version";
reason_desc(multiple_app_files) -> "src/...app.src files more than one. Cannot read application version";
reason_desc(_) -> "Error of unknown reason".

bye(Msg) ->
    bye("~s~n", [Msg]).

bye(Fmt, Args) ->
    bye(Fmt, Args, 0).

bye(Fmt, Args, ExitCode) ->
    io:format(Fmt, Args),
    halt(ExitCode).

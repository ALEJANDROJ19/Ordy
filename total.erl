-module(total).
-export([start/3]).

start(Id, Master, Jitter) ->
    spawn(fun() -> init(Id, Master, Jitter) end).

init(Id, Master, Jitter) ->
    {A1,A2,A3} = now(),
    random:seed(A1, A2, A3),
    receive
        {peers, Nodes} ->
            server(Master, seq:new(Id), seq:new(Id), Nodes, [], [], Jitter)
    end.

server(Master, MaxPrp, MaxAgr, Nodes, Cast, Queue, Jitter) ->
receive
    {send, Msg} ->
        Ref = make_ref(),
        request(Ref, Msg, Nodes, Jitter),
        NewCast = cast(Ref, Nodes, Cast),
        server(Master, MaxPrp, MaxAgr, Nodes, NewCast, Queue, Jitter);
    {request, From, Ref, Msg} ->
        NewMaxPrp = seq:increment(seq:max(MaxPrp, MaxAgr)),
        From ! {proposal, Ref , NewMaxPrp},
        NewQueue = insert(Ref, Msg, NewMaxPrp, Queue),
        server(Master, NewMaxPrp, MaxAgr, Nodes, Cast, NewQueue, Jitter);
    {proposal, Ref, Proposal} ->
        case proposal(Ref, Proposal, Cast) of
            {agreed, MaxSeq, NewCast} ->
                agree(Ref, MaxSeq, Nodes),
                server(Master, MaxPrp, MaxSeq, Nodes, NewCast, Queue, Jitter);
            NewCast ->
                server(Master, MaxPrp, MaxAgr, Nodes, NewCast, Queue, Jitter)
        end;
    {agreed, Ref, Seq} ->
        Updated = update(Ref, Seq, Queue),
        {Agreed, NewQueue} = agreed(Updated),
        deliver(Master, Agreed),
        NewMaxAgr = seq:max(Seq,MaxAgr),
        server(Master, MaxPrp, NewMaxAgr, Nodes, Cast, NewQueue, Jitter);
    stop ->
        ok
end.

request(Ref, Msg, Nodes, 0) ->
    Self = self(),
    lists:foreach(fun(Node) -> 
                      Node ! {request, Self, Ref, Msg}
                  end, 
                  Nodes);
request(Ref, Msg, Nodes, Jitter) ->
    Self = self(),
    lists:foreach(fun(Node) ->
                      T = random:uniform(Jitter),
                      timer:send_after(T, Node, {request, Self, Ref, Msg})end,
                  Nodes).
        
agree(Ref, Seq, Nodes)->
    lists:foreach(fun(Pid)-> 
					  Pid ! {agreed, Ref, Seq}         end, 
                  Nodes).

deliver(Master, Messages) ->
    lists:foreach(fun(Msg)-> 
                      Master ! {deliver, Msg} 
                  end, 
                  Messages).
                  
cast(Ref, Nodes, Cast) ->
    L = length(Nodes),
    [{Ref, L, seq:null()}|Cast].

proposal(Ref, Proposal, [{Ref, 1, Sofar}|Rest])->
    {agreed, seq:max(Proposal, Sofar), Rest};
proposal(Ref, Proposal, [{Ref, N, Sofar}|Rest])->
    [{Ref, N-1, seq:max(Proposal, Sofar)}|Rest];
proposal(Ref, Proposal, [Entry|Rest])->
    case proposal(Ref, Proposal, Rest) of
        {agreed, Agreed, Rst} ->
            {agreed, Agreed, [Entry|Rst]};
        Updated ->
            [Entry|Updated]
    end.
    
agreed([{_Ref, Msg, agrd, _Agr}|Queue]) ->
    {Agreed, Rest} = agreed(Queue),
    {[Msg|Agreed], Rest};
agreed(Queue) ->
    {[], Queue}.
    
update(Ref, Agreed, [{Ref, Msg, propsd, _}|Rest])->
    queue(Ref, Msg, agrd, Agreed, Rest);
update(Ref, Agreed, [Entry|Rest])->
    [Entry|update(Ref, Agreed, Rest)].
    
insert(Ref, Msg, Proposal, Queue) ->
    queue(Ref, Msg, propsd, Proposal, Queue).
    
queue(Ref, Msg, State, Proposal, []) ->
    [{Ref, Msg, State, Proposal}];
queue(Ref, Msg, State, Proposal, Queue) ->
    [Entry|Rest] = Queue,
    {_, _, _, Next} = Entry,
    case seq:lessthan(Proposal, Next) of
        true ->
            [{Ref, Msg, State, Proposal}|Queue];
        false ->
            [Entry|queue(Ref, Msg, State, Proposal, Rest)]
    end.

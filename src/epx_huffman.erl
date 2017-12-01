%%
%% Huffman encoder/decoder
%%   mainly support for the JPEG module
%%
-module(epx_huffman).

-export([decode/2, decode1/2, encode/2]).
-export([decode_dht/1, encode_dht/1]).
-export([build_decoder/1,build_encoder/1]).

-compile(export_all).

-import(lists, [reverse/1, map/2]).

%% A huffman decoder
decode(Bits, Encoder) when element(1, Encoder) == dict -> %% hack!
    decode(Bits, encoder_to_decoder(Encoder));
decode(Bits, Decoder) when is_list(Bits) ->
    decode(list_to_binary(Bits), Decoder);
decode(Bits, Decoder) when is_binary(Bits) ->
    decode_bin(Bits, Decoder, Decoder, []).

decode_bin(<<0:1,Bits/bits>>, {L,_}, Decoder, Acc) ->
    decode_bin(Bits, L, Decoder, Acc);
decode_bin(<<1:1,Bits/bits>>, {_,R}, Decoder, Acc) ->
    decode_bin(Bits, R, Decoder, Acc);
decode_bin(Bits, Code, Decoder,Acc) when is_integer(Code) ->
    decode_bin(Bits, Decoder, Decoder, [Code|Acc]);
decode_bin(<<>>, _, _, Acc) ->
    reverse(Acc).

%% decode 1 code
decode1(<<0:1,Bits/bits>>, {L,_}) -> decode1(Bits, L);
decode1(<<1:1,Bits/bits>>, {_,R}) -> decode1(Bits, R);
decode1(Bits, Code) when is_integer(Code) -> {Code,Bits}.


%% A huffman encoder
encode(Bytes, Encoder) when is_binary(Bytes) ->
    encode_bin(Bytes, Encoder, <<>>);
encode(Bytes, Encoder) when is_list(Bytes) ->
    encode_list(Bytes, Encoder, <<>>).

encode_list([B|Bs], Encoder, Acc) ->
    {Bits,Len} = dict:fetch(B,Encoder),
    encode_list(Bs, Encoder, <<Acc/bits, Bits:Len>>);
encode_list([], _Encoder, Acc) ->
    pad_bits(Acc).

encode_bin(<<B,Bs/binary>>, Encoder, Acc) ->
    {Bits,Len} = dict:fetch(B,Encoder),
    encode_bin(Bs, Encoder, <<Acc/bits, Bits:Len>>);
encode_bin(<<>>, _Encoder, Acc) ->
    pad_bits(Acc).

pad_bits(Acc) ->
    Pad = (8 - (bit_size(Acc) rem 8)) rem 8,
    <<Acc/bits, 0:Pad>>.


%%
%% Build encoder from [Byte]
%%
build_encoder(Bytes) ->
    FTab = count_frequency(Bytes, dict:new()),
    Tree = build_tree(reverse(lists:keysort(2,dict:to_list(FTab)))),
    build_encoder(Tree, 0, 0, dict:new()).

build_encoder({L,R}, Bits, Len, D) ->
    Bits1 = Bits bsl 1,
    D1 = build_encoder(L, Bits1, Len+1, D),
    build_encoder(R, Bits1 + 1, Len+1, D1);
build_encoder(Code, Bits, Len, D) ->
    dict:store(Code,{Bits,Len}, D).


build_tree([{T1,C1},{T2,C2}|List]) ->
    build_tree(sort_insert({{T1,T2},C1+C2}, List));
build_tree([{T,_C}]) ->
    T.

sort_insert(E={_T,C}, List0=[E1={_T1,C1}|List]) ->
    if C >= C1 ->
	    [E1 | sort_insert(E,List)];
       true ->
	    [E | List0]
    end;
sort_insert(E, []) ->
    [E].


count_frequency([C|Cs], D) ->
    count_frequency(Cs, count(C, D));
count_frequency(<<C,Cs/binary>>, D) ->
    count_frequency(Cs, count(C, D));
count_frequency([], D) ->
    D;
count_frequency(<<>>, D) ->
    D.

count(C, D) ->
    case dict:is_key(C, D) of
	true -> dict:update_counter(C,1,D);
	false -> dict:store(C,1,D)
    end.

%% Build decoder from list of {[0|1], Code}
build_decoder([]) ->
    x;
build_decoder([{[],C}]) ->
    C;
build_decoder(Codes) ->
    build_decoder(Codes,[],[]).

%% partion in two branches Z and O
build_decoder([{[0|Zs],Zc}|Codes], Z, O) ->
    build_decoder(Codes, [{Zs,Zc}|Z], O);
build_decoder([{[1|Os],Oc}|Codes], Z, O) ->
    build_decoder(Codes, Z, [{Os,Oc}|O]);
build_decoder([], Z, O) ->
    %% recursivly build decode for the parts
    {build_decoder(Z), build_decoder(O)}.

%% encoder_to_decoder
encoder_to_decoder(E) ->
    build_decoder(
      map(
	fun({Code,{Bits,Len}}) ->
		{[ B || <<B:1>> <= <<Bits:Len>>], Code}
	end, dict:to_list(E))).

%%
%%
%% JPEG support function to store huffman decoder
%% from DHT  (Define Huffman Table)
%%
encode_dht(Encoder) ->
    L = lists:sort(fun({_,{B1,L1}}, {_,{B2,L2}}) ->
			   if L1 == L2 -> B1 < B2;
			      true -> L1 < L2 
			   end
		   end, dict:to_list(Encoder)),
    encode_dht(L, 1, 0, <<>>, <<>>).


encode_dht(Cs0=[{Code,{_B,L1}}|Cs], L0,N, NTab, CTab) ->
    if L0 == L1 ->
	    encode_dht(Cs, L0, N+1, NTab, <<CTab/binary,Code>>);
       L0 < L1 ->
	    encode_dht(Cs0, L0+1, 0, <<NTab/binary,N>>, CTab)
    end;
encode_dht([], L0, N, NTab, CTab) ->       
    if L0 =< 16 ->
	    encode_dht([],L0+1,0,<<NTab/binary,N>>, CTab);
       true ->
	    (<<NTab/binary,CTab/binary>>)
    end.
    

%%
%% JPEG support function to reconstruct huffman decoder
%% from DHT  (Define Huffman Table)
%%

%% read the huffman code table
decode_dht(<<LTab:16/binary,CTab/binary>>) ->
    dec_dht(LTab,CTab,[],[]).

%% pick N codes 
dec_dht(<<N,LTab/binary>>, CTab, Cs, Codes) ->
    Cs1 = dht_level(Cs),
    {Cs2,Cs3} = lists:split(N, Cs1),
    dht_codes(Cs2, CTab, LTab, Cs3, Codes);
dec_dht(<<>>, CTab, _Cs, Codes) -> 
    Codes1 = reverse(Codes),
    Decoder = build_decoder(Codes1),
    {Decoder, CTab}.

dht_codes([C|Cs], <<Byte,CTab/binary>>, LTab, Cs1, Codes) ->
    dht_codes(Cs, CTab, LTab, Cs1, [{reverse(C),Byte}|Codes]);
dht_codes([], CTab, LTab, Cs1, Codes) ->
    dec_dht(LTab, CTab, Cs1, Codes).

dht_level([]) ->
    [[0], [1]];
dht_level(List) ->
    dht_level_(List).

dht_level_([C|Cs]) ->
    [[0|C],[1|C] | dht_level_(Cs)];
dht_level_([]) ->
    [].

%%
%% Test routines
%%

%%
%% Test data from:
%% http://www.impulseadventure.com/photo/jpeg-huffman-coding.html
%%
test_dht() ->
    DHT =
	<<0,2,1,3,3,2,4,2,6,7,3,4,2,6,2,115,

	 16#01,16#02,
	 16#03,
	 16#11,16#04,16#00,
	 16#05,16#21,16#12,
	 16#31,16#41,
	 16#51,16#06,16#13,16#61,
	 16#22, 16#71,
	 16#81, 16#14, 16#32, 16#91, 16#A1, 16#07, 
	 16#15, 16#B1, 16#42, 16#23, 16#C1, 16#52, 16#D1, 
	 16#E1, 16#33, 16#16, 
	 16#62, 16#F0, 16#24, 16#72, 
	 16#82, 16#F1, 
	 16#25, 16#43, 16#34, 16#53, 16#92, 16#A2, 16#B2, 16#63, 
	 16#73, 16#C2, 16#35, 16#44, 16#27, 16#93, 16#A3, 16#B3, 
	 16#36, 16#17, 16#54, 16#64, 16#74, 16#C3, 16#D2, 16#E2,
	 16#08, 16#26, 16#83, 16#09, 16#0A, 16#18, 16#19, 16#84,
	 16#94, 16#45, 16#46, 16#A4, 16#B4, 16#56, 16#D3, 16#55, 
	 16#28, 16#1A, 16#F2, 16#E3, 16#F3, 16#C4, 16#D4, 16#E4, 
	 16#F4, 16#65, 16#75, 16#85, 16#95, 16#A5, 16#B5, 16#C5, 
	 16#D5, 16#E5, 16#F5, 16#66, 16#76, 16#86, 16#96, 16#A6, 
	 16#B6, 16#C6, 16#D6, 16#E6, 16#F6, 16#37, 16#47, 16#57, 
	 16#67, 16#77, 16#87, 16#97, 16#A7, 16#B7, 16#C7, 16#D7, 
	 16#E7, 16#F7, 16#38, 16#48, 16#58, 16#68, 16#78, 16#88, 
	 16#98, 16#A8, 16#B8, 16#C8, 16#D8, 16#E8, 16#F8, 16#29, 
	 16#39, 16#49, 16#59, 16#69, 16#79, 16#89, 16#99, 16#A9, 
	 16#B9, 16#C9, 16#D9, 16#E9, 16#F9, 16#2A, 16#3A, 16#4A, 
	 16#5A, 16#6A, 16#7A, 16#8A, 16#9A, 16#AA, 16#BA, 16#CA, 
	 16#DA, 16#EA, 16#FA
	 >>,
    decode_dht(DHT).

test_text() ->
    "1234567891234567891231231231231230".

test_dht1() ->
    Text = test_text(),
    E = build_encoder(Text),
    CText = encode(Text, E),
    DHT = encode_dht(E),
    D = decode_dht(DHT),
    decode(CText, D).

    
    

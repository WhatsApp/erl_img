%%
%% DCT/IDCT Discrete Cosine Transform and its inverse
%%
-module(epx_dct).

-export([forward_8x8/1,
	 inverse_8x8/1]).

-export([forward_8x8_0/1,
	 forward_8x8_1/1,
	 inverse_8x8_0/1,
	 inverse_8x8_1/1]).

-export([dct_matrix/1, dct_transposed_matrix/1]).

-export([transpose/1, multiply/2]).

-import(lists, [map/2, reverse/1]).	 

%%
%% Calulate the FDCT over a 8x8 matrix in row order format
%%
%% A=[[a00 a01 ... a07]
%%    [a10 a11 ... a17]
%%    ...
%%    [a70 a71 ...a77]]
%%
forward_8x8(A) ->
    forward_8x8_1(A).

inverse_8x8(F) ->
    inverse_8x8_1(F).


%%
%% Calculate the FDCT over A 8x8 (as 64 element list)
%%
%% The 64 elements are either Y|Cr|Cb
%%
%% N=8
%% F(u,v) = 2/N*(c(u)*c(v)) * 
%%            sum(x=0..7,
%%              sum(y=0..7, 
%%                 f(x,y) * cos((2x+1/16)*u*pi)*cos((2y+1)/16*v*pi)
%%
%%  c(k) == 1/sqrt(2)  k = 0
%%       == 1          k != 0
%%
%%
forward_8x8_0(A) ->
    forward_8x8_0(8,8,A,[],[]).

-define(PI, 3.141592653589793).
-define(SQRT2, 1.4142135623730951).

%% N=8
c(0)  -> 1/?SQRT2;
c(_I) -> 1.


forward_8x8_0(0,0,_A,_Fy,F) ->
    F;
forward_8x8_0(0,V,A,Fy,F) ->
    forward_8x8_0(8,V-1,A,[],[Fy|F]);
forward_8x8_0(U,V,A,Fy,F) ->
    Fxy = (1/4)*c(U-1)*c(V-1)*forward_8x8_xy(U-1,V-1,-1,-1,[],A,0),
    forward_8x8_0(U-1,V,A,[Fxy|Fy],F).
    
forward_8x8_xy(U,V,X,Y,[Axy|Ay],A, Fxy) ->
    Fxy1 = Fxy+Axy*
	math:cos(?PI*((2*X+1)*U)/16)*
	math:cos(?PI*((2*Y+1)*V)/16),
    forward_8x8_xy(U,V,X+1,Y,Ay,A,Fxy1);
forward_8x8_xy(U,V,_X,Y,[],[Ay|A], Fxy) ->
    forward_8x8_xy(U,V,0,Y+1,Ay,A,Fxy);
forward_8x8_xy(_U,_V,_X,_Y,[],[],Fxy) ->
    Fxy.


%% Matrix variant of the above
%% Y = (A*X)*At
forward_8x8_1(X) ->
    A = dct_matrix(8),
    At = dct_transposed_matrix(8),
    multiply(multiply(A, X), At).

%%
%% Calculate the IDCT over F 8x8 (as 64 element list)
%% 
%% A(X,Y) = sum(u=0..N-1,
%%             sum(v=0..N-1, 
%%               c(u)*c(v)*F(u,v)*cos((2x+1/2*N)*u*pi)*cos((2y+1)/2*N*v*pi)
%% N=8
%% T(x,u) = c(u)cos((2x+1)/16*u*pi)
%% A(X,Y) = sum(u=0..7, sum(v=0..7, F(u,v)*T(x,u)*T(y,v)))
%%        = sum(u=0..7, T(x,u)sum(v=0..7,F(u,v)T(y,v)))
%%        = sum(u=0..7,T(x,y)
%%                    (F(u,0)/sqrt(2) + sum(v=1..7,F(u,v)T(y,v))))
%%

%% Multiplications per element (could be) = 8*8 = 64
inverse_8x8_0(F) ->
    inverse_8x8_0(8,8,F,[],[]).

inverse_8x8_0(0,0,_F,_Ay,A) ->
    A;
inverse_8x8_0(0,Y,F,Ay,A) ->
    inverse_8x8_0(8,Y-1,F,[],[Ay|A]);
inverse_8x8_0(X,Y,F,Ay,A) ->
    Axy = (1/4)*inverse_8x8_uv(X-1,Y-1,-1,-1,[],F,0),
    inverse_8x8_0(X-1,Y,F,[Axy|Ay],A).
    
inverse_8x8_uv(X,Y,U,V,[Fuv|Fu],F, I) ->
    I1 = I+c(U)*c(V)*Fuv*
	math:cos(?PI/16*((2*X+1)*U))*
	math:cos(?PI/16*((2*Y+1)*V)),
    inverse_8x8_uv(X,Y,U+1,V,Fu,F, I1);
inverse_8x8_uv(X,Y,_U,V,[],[Fu|F], I) ->
    inverse_8x8_uv(X,Y,0,V+1,Fu,F,I);
inverse_8x8_uv(_X,_Y,_U,_V,[],[],I) ->
    I.


%% Matrix variant of the above
%% X = (At*Y)*A
%% Multiplications per pixel = 8+8 = 16
inverse_8x8_1(Y) ->
    A = dct_matrix(8),
    At = dct_transposed_matrix(8),
    multiply(multiply(At, Y), A).

%%
%% Generate the DCT matrix A
%% where a(u,x) = c(u,N)*cos((pi*(2x+1)*u)/(2N))
%%
c(0,N)  -> math:sqrt(1/N);
c(_I,N) -> math:sqrt(2/N).

dct_matrix(8) ->
    dct_matrix_8();
dct_matrix(N) ->
    Seq = lists:seq(0, N-1),
    [ [c(U,N)*math:cos(math:pi()*(((2*X+1)*U)/(2*N))) ||
	  X <- Seq] ||	U <- Seq].

dct_transposed_matrix(8) ->
    dct_transposed_matrix_8();
dct_transposed_matrix(N) ->
    Seq = lists:seq(0, N-1),
    [ [c(U,N)*math:cos(math:pi()*(((2*X+1)*U)/(2*N))) ||
	  U <- Seq] || X <- Seq].

%% Matrix multiply 
multiply([], _B) ->
    [];
multiply([Ai|A], B) ->
    %% multiply A with every column in B
    Ci = mcolumns(Ai, B),
    [Ci | multiply(A, B)].
    
mcolumns(_Ai, [[]|_]) ->
    [];
mcolumns(Ai, B) ->
    {S, B1} = mcolumn(Ai, B, [], 0),
    [S | mcolumns(Ai, B1)].

mcolumn([Aik|Ai], [[Bkj|Bk]|B], B1, S) ->
    mcolumn(Ai, B, [Bk | B1], S + Aik*Bkj);
mcolumn([], [], B1, S) ->
    {S, reverse(B1)}.

%% Transpose a matrix
transpose(A) ->
    At = lists:duplicate(length(A), []),
    transpose(A, At).

transpose([R|Rs], At) ->
    At1 = consl(R, At),
    transpose(Rs, At1);
transpose([], At) ->
    map(fun(Row) -> reverse(Row) end, At).
		
consl([E|Es], [Row|Rs]) ->
    [[E|Row] | consl(Es, Rs)];
consl([], []) ->
    [].

dct_matrix_8() ->
[[0.3535533905932738,0.3535533905932738,0.3535533905932738,
  0.3535533905932738,0.3535533905932738,0.3535533905932738,
  0.3535533905932738,0.3535533905932738],
 [0.4903926402016152,0.4157348061512726,0.27778511650980114,
  0.09754516100806415,-0.0975451610080641,-0.277785116509801,
  -0.4157348061512727,-0.4903926402016152],
 [0.46193976625564337,0.19134171618254492,
  -0.19134171618254486,-0.46193976625564337,
  -0.46193976625564337,-0.19134171618254517,0.191341716182545,
  0.46193976625564326],
 [0.4157348061512726,-0.0975451610080641,-0.4903926402016152,
  -0.2777851165098011,0.2777851165098009,0.4903926402016152,
  0.09754516100806439,-0.41573480615127256],
 [0.3535533905932738,-0.35355339059327373,
  -0.35355339059327384,0.35355339059327373,
  0.35355339059327384,-0.35355339059327334,
  -0.3535533905932736,0.3535533905932733],
 [0.27778511650980114,-0.4903926402016152,
  0.09754516100806414,0.4157348061512728,-0.41573480615127256,
  -0.09754516100806401,0.4903926402016153,
  -0.27778511650980076],
 [0.19134171618254492,-0.46193976625564337,
  0.46193976625564326,-0.19134171618254492,
  -0.19134171618254528,0.46193976625564337,
  -0.46193976625564315,0.19134171618254478],
 [0.09754516100806415,-0.2777851165098011,0.4157348061512728,
  -0.4903926402016153,0.4903926402016152,-0.4157348061512725,
  0.27778511650980076,-0.09754516100806428]].

dct_transposed_matrix_8() ->
[[0.3535533905932738,0.4903926402016152,0.46193976625564337,
  0.4157348061512726,0.3535533905932738,0.27778511650980114,
  0.19134171618254492,0.09754516100806415],
 [0.3535533905932738,0.4157348061512726,0.19134171618254492,
  -0.0975451610080641,-0.35355339059327373,
  -0.4903926402016152,-0.46193976625564337,
  -0.2777851165098011],
 [0.3535533905932738,0.27778511650980114,
  -0.19134171618254486,-0.4903926402016152,
  -0.35355339059327384,0.09754516100806414,
  0.46193976625564326,0.4157348061512728],
 [0.3535533905932738,0.09754516100806415,
  -0.46193976625564337,-0.2777851165098011,
  0.35355339059327373,0.4157348061512728,-0.19134171618254492,
  -0.4903926402016153],
 [0.3535533905932738,-0.0975451610080641,
  -0.46193976625564337,0.2777851165098009,0.35355339059327384,
  -0.41573480615127256,-0.19134171618254528,
  0.4903926402016152],
 [0.3535533905932738,-0.277785116509801,-0.19134171618254517,
  0.4903926402016152,-0.35355339059327334,
  -0.09754516100806401,0.46193976625564337,
  -0.4157348061512725],
 [0.3535533905932738,-0.4157348061512727,0.191341716182545,
  0.09754516100806439,-0.3535533905932736,0.4903926402016153,
  -0.46193976625564315,0.27778511650980076],
 [0.3535533905932738,-0.4903926402016152,0.46193976625564326,
  -0.41573480615127256,0.3535533905932733,
  -0.27778511650980076,0.19134171618254478,
  -0.09754516100806428]].
    
    

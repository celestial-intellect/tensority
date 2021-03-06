module MA = Multidim_array
module A=Array
let (@?) = A.unsafe_get
let (%) = A.unsafe_set
let (=:) = (@@)


type 'x t =  { contr:('n * 'a) Shape.eq
             ; cov:('n2 * 'b) Shape.eq
             ; strides: 'n Stride.t * 'n2 Stride.t
             ; offset: int
             ; array : float array
             }
  constraint 'x = < contr:'n * 'a; cov:'n2 * 'b >

type 'dim vec = <contr:'dim Shape.single; cov:Shape.empty> t
type ('l,'c) matrix = <contr:'l Shape.single; cov: 'c Shape.single> t
type ('d1,'d2,'d3) t3 = <contr:('d1,'d2) Shape.pair; cov: 'd3 Shape.single> t

module Unsafe = struct
let create ~contr ~cov array =
  let len = (Shape.size cov) * (Shape.size contr) in
  let len' = A.length array in
  if len <> len' then
    raise @@ Signatures.Dimension_error( "Tensor.unsafe_create", len, len' )
  else
    {cov;contr; array; strides= Stride.create_2 contr cov; offset = 0 }

end

[%%indexop.arraylike
  let get: <contr:'a; cov:'b> t -> ('a Shape.lt * 'b Shape.lt ) -> float = fun t
    (contr,cov) ->
    let p =
      t.offset + Stride.position_2 t.strides contr cov in
    t.array @? p


  let set: < contr:'a; cov:'b > t -> ('a Shape.lt * 'b Shape.lt ) -> float -> unit
    = fun t (contr,cov) value ->
      let p =
        t.offset + Stride.position_2 t.strides contr cov in
    t.array % p =: value
]


let cov_size t = Shape.size t.cov
let contr_size t = Shape.size t.contr
let size t = cov_size t * contr_size t

let len t = A.length t.array
let contr_dims t = t.contr
let cov_dims t = t.cov
let is_sparse t = len t <> size t


let const ~contr ~cov x=
  let len = Shape.size cov * Shape.size contr in
  let array = A.make len x in
  Unsafe.create ~contr ~cov array

let zero ~contr ~cov = const ~contr ~cov  0.

let init_sh f ~contr ~cov =
  let r = zero ~contr ~cov in
  Shape.iter_on contr ( fun contr ->
      Shape.iter_on cov ( fun cov ->
          r.(contr,cov) <- f contr cov
        )
    )
; r

let pp ppf t =
  let order = Shape.order t.cov in
  let sep ?(start=0) ppf n =
    match n + start with
      | 0 -> Format.fprintf ppf ",@ "
      | 1 -> Format.fprintf ppf ";@ "
      | 2 -> Format.fprintf ppf "@,"
      | _n ->  Format.fprintf ppf "@," in
  let up _ = Format.fprintf ppf "@["
  and down _ = Format.fprintf ppf "@]" in
  let pp_scalar ppf x= Format.fprintf ppf "%f" x in
  let pp_cov ppf t contr  =
    Shape.iter_sep ~up ~down ~sep:(sep ppf) t.cov ~f:(fun cov ->
        pp_scalar ppf t.(contr,cov)
      ) in
  let pp_array ppf t =
    Shape.iter_sep ~up ~down
      ~sep:(sep ~start:order ppf) ~f:(pp_cov ppf t) t.contr in
  Format.fprintf ppf "@[{contr=%a;@ cov=%a;@ array=%a}@]"
    Shape.pp t.contr Shape.pp t.cov
    pp_array t

let show t = Format.asprintf "%a" pp t

let reshape t (contr,cov) =
  if is_sparse t then
    raise @@ Invalid_argument "Tensor.reshape: sparse tensor cannot be reshaped"
  else
    let l = len t and dim = Shape.(size contr * size cov) in
    if l <> dim then
      raise @@ Signatures.Dimension_error("Tensor.reshape", l, dim)
    else
      { t with contr; cov;
               strides = Stride.create_2 contr cov }

let matrix dim_row dim_col f: ('a,'b) matrix =
  let size = Nat.(to_int dim_row * to_int dim_col) in
  let array = A.create_float size in
  let pos = ref 0 in
  let () = (*init*)
    Nat.iter_on dim_row (fun i ->
        Nat.iter_on dim_col (fun j ->
            array % !pos =: f i j
          ; incr pos
          )
      ) in
  Unsafe.create ~contr:[dim_row] ~cov:[dim_col] array

let sq_matrix dim f = matrix dim dim f

let vector (dim:'a Nat.eq) f :' a vec=
  Unsafe.create ~contr:[dim] ~cov:[] @@ Nat.map f dim

;; [%%indexop
let get_1: 'a vec -> 'a Nat.lt -> float = fun t n ->
  t.([n],[])

let set_1: 'a vec -> 'a Nat.lt -> float -> unit =
  fun t n x -> t.([n],[]) <- x

let get_2: ('a,'b) matrix -> 'a Nat.lt -> 'b Nat.lt -> float =
  fun t n m -> t.([n],[m])

let set_2: ('a,'b) matrix -> 'a Nat.lt -> 'b Nat.lt -> float -> unit =
  fun t n m x -> t.([n],[m]) <- x


let get_3: ('a,'b,'c) t3 -> 'a Nat.lt -> 'b Nat.lt -> 'c Nat.lt -> float =
  fun t k l m -> t.([k;l],[m])

let set_3:
  ('a,'b,'c) t3
  -> 'a Nat.lt -> 'b Nat.lt -> 'c Nat.lt
  -> float
  -> unit =
  fun t k l m x -> t.([k;l],[m]) <- x
]

;;

let delta i j = if Nat.to_int i = Nat.to_int j then 1. else 0.
let id dim = sq_matrix dim delta
let base dim p =
  let open Nat in
  let Truth = p %<% dim in
  vector dim @@ delta p

let endo_dim (mat: ('a,'a) matrix) =
  let open Shape in
  match mat.contr with
  | [dim] -> dim

module Sparse = struct

  let transpose t =
    let tt = zero ~cov:t.contr ~contr:t.cov in
    Shape.iter_on t.contr ( fun contr ->
        Shape.iter_on t.cov ( fun cov ->
            tt.(cov,contr) <- t.(contr,cov)
          )
      )
  ; tt

  let mult t1 t2 =
    let r = zero ~contr:t1.contr ~cov:t2.cov in
    Shape.iter_on t1.contr (fun i ->
        Shape.iter_on t1.cov (fun k ->
            Shape.iter_on t2.cov ( fun j ->
                r.(i,j)<- r.(i,j) +. t1.(i,k) *. t2.(k,j)
              )
          )
      )
  ; r


  let trace t =
    let s = ref 0. in
    Shape.iter_on t.contr ( fun sh ->
        s := !s +. t.(sh,sh)
      )
  ; !s

  let full_contraction t1 t2 =
    let s = ref 0. in
    Shape.iter_on t1.contr ( fun contr ->
        Shape.iter_on t1.cov ( fun cov ->
            s := !s +. t1.(contr,cov) *. t2.(cov,contr)
          )
      )
  ; !s

  let scalar_product t1 t2 =
    let s = ref 0. in
    Shape.iter_on t1.contr ( fun contr ->
        Shape.iter_on t1.cov ( fun cov ->
            s := !s +. t1.(contr,cov) *. t2.(contr,cov)
          )
      )
  ; !s

  let map2 ( <+> ) t1 t2 =
    init_sh ~contr:t1.contr ~cov:t1.cov (fun contr cov ->
        t1.(contr,cov) <+> t2.(contr,cov)
      )

  let scalar_map f t1 =
    init_sh ~contr:t1.contr ~cov:t1.cov
      (fun contr cov -> f t1.(contr,cov))


end


(** Optimized version when tensor are not sparse *)
module Full = struct

let map2 ( <@> ) (t1:'sh t) (t2:'sh t) : 'sh t =
  let array = A.mapi ( fun i x -> x <@> t2.array @? i ) t1.array in
  { t1 with array }


let iter_int n kont f =
  for i = 0 to n - 1 do
    kont (f i)
  done
let (^) = iter_int
let stop () = ()
let iter_on f = f

let transpose: < contr:'left; cov:'right > t -> < contr:'right; cov:'left > t =
  fun t1 ->
  let left =  contr_size t1
  and right = cov_size t1 in
  let array = A.make (len t1) 0. in
  let () =
    iter_on (left ^ right ^ stop) (fun i j ->
        t1.array % (i * right + j ) =: t1.array @? (j * right + i)
      ) in
  Unsafe.create ~contr:t1.cov ~cov:t1.contr array

let mult (t1: <contr:'left; cov:'mid> t) (t2: <contr:'mid; cov:'right> t) :
  <contr:'left; cov:'right> t =
  let left_dim = contr_size t1
  and middle_dim = cov_size t1
  and right_dim = cov_size t2 in
  let l = t1.array and r = t2.array in
  let len = left_dim * right_dim in
  let array = A.make len 0. in
  iter_on (left_dim ^ middle_dim ^ right_dim ^ stop)
    ( fun i k j ->
        let pos = i * right_dim + j in
        array % pos =:
        (array @? pos) +.
        (l @? i * middle_dim + k ) *. (r @? k * right_dim + j)
    );
  Unsafe.create ~contr:t1.contr ~cov:t2.cov array


let trace (t1: <contr:'a; cov:'a> t ) =
  let size = contr_size t1 in
  let s = ref 0. in
  iter_on (size ^ stop) (fun i ->
      s := !s +. (t1.array @? i + size * i)
    )
  ; !s

let full_contraction (t1: <contr:'a; cov:'b> t ) (t2: < contr:'b; cov:'a > t) =
  let left = contr_size t1 and right = cov_size t1 in
  let s = ref 0. in
  iter_on (left ^ right ^ stop) (fun i j ->
      s := !s +. (t1.array @? i + left * j) *. (t2.array @? j + right * i)
    )
  ; !s

let scalar_product (t1: 'sh t) (t2: 'sh t) =
  let l = len t1 in
  let s =ref 0. in
  for i = 0 to l - 1 do
    s:= !s +. (t1.array @? i) *. (t2.array @? i)
  done
  ; !s

let scalar_map f t =
  { t with array = A.map f t.array }

end

let transpose t =
  if is_sparse t then
    Sparse.transpose t
  else
    Full.transpose t

let mult t1 t2 =
  if is_sparse t1 || is_sparse t2 then
    Sparse.mult t1 t2
  else
    Full.mult t1 t2

let trace t =
  if is_sparse t then
    Sparse.trace t
  else
    Full.trace t

let full_contraction t1 t2 =
  if is_sparse t1 || is_sparse t2 then
    Sparse.full_contraction t1 t2
  else
    Full.full_contraction t1 t2


let scalar_product t1 t2 =
  if is_sparse t1 || is_sparse t2 then
    Sparse.scalar_product t1 t2
  else
    Full.scalar_product t1 t2


  let map2 ( <+> ) t1 t2 =
  if is_sparse t1 || is_sparse t2 then
    Sparse.map2 (<+>) t1 t2
  else
    Full.map2 (<+>) t1 t2


let scalar_map f t =
  if is_sparse t then
    Sparse.scalar_map f t
  else
    Full.scalar_map f t

let pow_int x k =
  let ( * ) = mult in
  let rec aux x m k = match k with
    | 0 -> m
    | 1 -> m * x
    | k when k land 1 = 1 -> aux (x*x) (x*m) (k lsr 1)
    | k -> aux (x*x) m (k lsr 1) in
  let id =  id @@ endo_dim x in
  aux x id k

module Operators = struct
let ( * ) x y = mult x y
let ( |*| ) x y = scalar_product x y
let ( + ) t1 t2 = map2 ( +. ) t1 t2
let ( - ) t1 t2 = map2 ( -. ) t1 t2

let ( *. )  l t = scalar_map ( ( *. ) l ) t

let ( /. ) l t = scalar_map ( fun x -> x /. l ) t

let ( ** )= pow_int

end

(* to do:
   * moving indices up/down
*)

(*
let full_up: type left right tl.
  (<l: left; tl:right>, <l:right; tl:tl> ) t -> (<l:left;tl:tl>, 'a Shape.empty ) t =
  fun t1 ->
    Shape.{ t1 with contr=t1.contr @ t1.cov; cov = [] }

let up1: type left right dim tl tl2.
  (<l: left; tl:dim->tl >, <l:dim -> right; tl:tl2> ) t ->
  (<l:left;tl:tl>,<l:right;tl:tl2> ) t = fun t ->
  let open Shape in
  match t.cov with
  | dim::right -> { t with contr = t.contr @ [dim] ; cov = right }
*)

let copy t =
  if is_sparse t then
  init_sh ~contr:t.contr ~cov:t.cov
    ( fun i j -> t.(i,j) )
  else
    { t with array = A.copy t.array }

let partial_copy (type na a nb b nc c nd d)
    (t:<contr:na * a; cov: nb * b> t)
    (f1,f2: (na * a, nc * c) Mask.s * ( nb * b, nd * d) Mask.s)
    : <contr: nc * c; cov: nd * d> t
  =
  let contr = Mask.filter t.contr f1 in
  let cov = Mask.filter t.cov f2 in
  let tnew = zero ~contr ~cov in
  Mask.iter_extended_dual
    (fun sh2 sh2' ->
       Mask.iter_extended_dual (
         fun sh1 sh1' ->
           tnew.(sh1,sh2) <- t.(sh1',sh2')
       ) contr f1
    )  cov f2;
  tnew

let slice t (f1,f2) =
  let s1, s2 = t.strides in
  let offset, s1 = Stride.filter s1 f1 in
  let offset_2, s2 = Stride.filter s2 f2 in
  let contr, cov = Mask.filter t.contr f1, Mask.filter t.cov f2 in
  { t with contr; cov; offset = offset + offset_2; strides = (s1, s2) }

let blit t t2 =
  Shape.iter ( fun sh' ->
      Shape.iter ( fun sh ->
          t.(sh,sh')<- t2.(sh,sh')
        ) t.contr
    ) t.cov

let partial_blit t (f1,f2) t2 =
  Mask.iter_masked_dual ( fun sh2 sh2' ->
      Mask.iter_masked_dual ( fun sh sh' ->
          t.(sh,sh2) <- t2.(sh',sh2')
        ) t.contr f1
    ) t.cov f2


let%indexop.stringlike get = slice
and set = partial_blit

exception Break

let det ( mat : <contr:'a Shape.single; cov:'a Shape.single> t): float=
  let abs = abs_float in
  let dim = endo_dim mat in
  let mat = copy mat in
  let sign = ref 1. in
  let perm = MA.ordinal dim in
  let ( ! ) k = MA.(  perm.{k} ) in
  let swap i i' =
    if i <> i' then
      let tmp = !i in
      let open MA in
      perm.{i} <- !i'
    ; perm.{i'} <- tmp
    ; sign.contents<- -.sign.contents
  in
  let pivot j =
    let find_max (i,max) k =
      let abs_k = abs_float mat.{ !k, j } in
      if abs_k > max then (k,abs_k) else (i,max) in
    let start = Nat.succ j and acc = j, abs mat.{!j,j} in
    let i, max  =
      Nat.partial_fold ~stop:dim ~start ~acc find_max in
    if max > 0. then swap j i else raise Break in
  let transl ?(start=0) ~from ~to_ coeff =
    Nat.partial_iter ~start ~stop:dim (fun j ->
        mat.{!to_,j} <- mat.{!to_,j} +. coeff *. mat.{!from,j}
      )
  in
  try
    Nat.iter_on dim (fun i ->
    pivot i;
    let c = mat.{!i,i} in
    Nat.partial_iter ~start:(Nat.succ i) ~stop:dim
      (fun to_ -> transl ~start:(Nat.to_int i) ~from:i ~to_ (-. mat.{!to_,i}/. c) )
      )
  ; Nat.fold (fun p k -> p *. mat.{!k,k} ) sign.contents dim
  with Break -> 0.

(** Given (n-1) vectors of dimension n, compute the normal to the hyperplane
    defined by these vectors with norm equal to their (n-1)-volume;
    sometimes erroneously called vector or cross product in dimension 3.
    * raise Invalid_argument if array = [||]
    * raise dimension_error if array lenght and vector dimension disagrees
*)
let normal (array: 'dim vec array): 'dim vec =
  let nvec = A.length array in
  if nvec = 0 then raise @@
    Invalid_argument "Tensor.normal expects array of size >0";
  let open Shape in
  let [dim] = (array @? 0).contr in
  let module Dyn = Nat.Dynamic(struct let dim = nvec end) in
  let open Nat_defs in
  match Nat.Sum.( Dyn.dim + _1 =? dim ) with
  | None -> raise @@
    Signatures.Dimension_error( "Tensor.normal", nvec + 1 , Nat.to_int dim )
  | Some proof ->
    let (%+%) = Nat.Sum.adder proof in
    let minor k = det @@ sq_matrix Dyn.dim (fun i j ->
        let offset =
          if Nat.( to_int i < to_int k) then _0p else _1p in
        (array @? Nat.to_int j).{i %+% offset}
      )
    in
    vector dim minor

include Operators

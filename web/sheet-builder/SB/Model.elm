module SB.Model where

import Dict exposing (Dict)
import Set exposing (Set)

type Term
  = Literal Atom
  | TList (List ListComponent)
  | TSheet Sheet
  | UnaryOp UOp Atom
  | BinaryOp BOp Atom Atom
  | SheetWith Ref Atom
  | SheetInput Ref
  | SheetOutput Ref
  --| Access Accessor
  --| Apply
  --| Identify (Identifier ref)  TODO: need to be able to push name changes
type UOp
  = UNot
  | UAddInvert
  | URound
  | UFloor
  | UCeiling
type BOp
  = BCompareEQ
  | BCompareLT
  | BCompareLTE
  | BCompareGT
  | BCompareGTE
  | BArithmetic (Float -> Float -> Float)
  | BStringConcat
  | BStringSubrange
  | BStringReplace
type Atom
  = ARef Ref
  | AUnit
  | ABool Bool
  | AString String
  | AInt Int
  | AFloat Float
type alias Accessor ref = { collection : ref, key : Atom ref }
type alias Identifier ref = { namespace : ref, nref : NamedRef ref }
type alias NamedRef ref = { name : Name, ref : ref }

type Value = VAtom Atom | VList (List ListComponent) | VSheet Sheet
type ListComponent
  = LCElements (List Atom)
  | LCSplice Ref
  | LCIteration Iteration
type alias Sheet =
  { elements : List Ref -- TODO: labels
  , owned : Set Ref -- not all embedded elements are owned
  , input : Atom  -- the parameter comes with an example
  , output : Atom
  }
type LayoutOrientation = Vertical | Horizontal

type alias Name = String
type alias Ref = Int

type alias Iteration =
  { procedure : Ref
  , length : Ref
  }

type alias Environment =
  { terms : Dict Ref Term
  , finished : Dict Ref (Maybe Value)
  , pending : Set Ref
  , scheduleIn : List Ref
  , scheduleOut : List Ref
  , uid : Int
  }
envEmpty =
  { terms = Dict.empty
  , finished = Dict.empty
  , pending = Set.empty
  , scheduleIn = []
  , scheduleOut = []
  , uid = 0
  }
schedulePush ref env = { env | pending = Set.insert ref env.pending,
                               scheduleIn = ref :: env.scheduleIn }
schedulePop env = case env.scheduleOut of
  [] -> case List.reverse env.scheduleIn of
          [] -> Nothing
          refs -> schedulePop { env | scheduleIn = [], scheduleOut = refs }
  ref::refs -> Just (ref, { env | scheduleOut = refs,
                                  pending = Set.remove ref env.pending})

nextRef env = (env.uid, { env | uid = env.uid + 1 })
updateTerm ref term env = { env | terms = Dict.insert ref term env.terms }
newTerm term env =
  let (ref, env') = nextRef env
      env'' = updateTerm ref term env'
  in (ref, env'')
refTerm ref { terms } = case Dict.get ref terms of
  Just term -> term
  Nothing -> Literal AUnit
refValue ref { finished } = Dict.get ref finished
finishRef ref val env = { env | finished = Dict.insert ref val env.finished }

dependencyRefs term = case term of
  Literal (ARef ref) -> Set.singleton ref
  BinaryOp _ lhs rhs ->
    Set.union (dependencyRefs <| Literal lhs) (dependencyRefs <| Literal rhs)
  _ -> Set.empty
-- TODO: account for visibility
rootRefs term = case term of
  --TList lcs ->
  --TSheet sheet ->
  _ -> dependencyRefs term

resultFoldl op acc xs = case xs of
  [] -> Ok acc
  yy::ys -> op yy acc `Result.andThen` \acc' -> resultFoldl op acc' ys

schedule ref env =
  let loop ref (seen, env) =
        if (Set.member ref env.pending || Dict.member ref env.finished) then
           Ok (seen, env)
        else if Set.member ref seen then Err "TODO: cyclic dependency"
        else
          let seen' = Set.insert ref seen
              deps = dependencyRefs <| refTerm ref env
          in resultFoldl loop (seen', env) (Set.toList deps) `Result.andThen`
             \(seen'', env') -> Ok (seen'', schedulePush ref env')
  in loop ref (Set.empty, env) `Result.andThen` \(_, env') -> Ok env'

--evalTerm term env = case term of
  --Literal atom -> (Ok atom, env)
  --BinaryOp op lhs rhs ->
    --let result = case op of
      --BArithmetic op -> arithApply op lhs rhs  -- TODO
      --_ -> Err "TODO"
    --in (result, env)
  --_ -> (Err "TODO", env)
--evalRef ref env = case Dict.get ref env.terms of
  --Nothing -> (Err "TODO: missing term for ref", env)
  --Just term -> evalTerm term env `Result.andThen`
    --\atom -> ... value ...
--evalSchedule1 env = schedulePop env `Maybe.andThen`
  --\(ref, env') -> Just <| evalRef ref env'

mapFst f (a, b) = (f a, b)
mapSnd f (a, b) = (a, f b)

afloat atom = case atom of
  AInt int -> Ok <| toFloat int
  AFloat float -> Ok float
  _ -> Err "afloat: expected a number"

arithApply op alhs arhs =
  afloat alhs `Result.andThen`
  \flhs -> afloat arhs `Result.andThen`
  \frhs -> Ok <| AFloat <| op flhs frhs

valueAtom ref value = case value of
  VAtom atom -> atom
  _ -> ARef ref

-- TODO: separate pending computation scheduling
evalAtom atom pending env = case atom of
  ARef ref -> case Dict.get ref env.finished of
    Just value -> case value of
      VAtom atom -> (Ok atom, env)
      _ -> (Ok <| ARef ref, env)
    Nothing ->
      if Set.member ref pending then (Err "TODO: cyclic computation", env)
      else case Dict.get ref env.terms of
        Nothing -> (Err "TODO: missing term for ref", env)
        Just term ->
          let (result, env') = eval term (Set.insert ref pending) env
          in case result of
            Err err -> (Err err, env')
            Ok value -> (Ok <| valueAtom ref value, finishRef ref value env')
  _ -> (Ok <| atom, env)

asheet atom env = case atom of
  ARef ref -> case refValue ref env of
    Nothing -> Err "asheet: reference points to nothing"
    Just value -> case value of
      VSheet sheet -> Ok sheet
      _ -> Err "asheet: expected reference to point to a sheet"
  _ -> Err "asheet: expected a reference"

evalSheet sref pending env =
  let (ratom, env') = evalAtom (ARef sref) pending env
      result = ratom `Result.andThen` \atom -> asheet atom env'
  in (result, env')

eval term pending env = case term of
  Literal atom -> (Result.map VAtom) `mapFst` evalAtom atom pending env
  BinaryOp op lhs rhs ->
    let (rlhs, env') = evalAtom lhs pending env
        (rrhs, env'') = evalAtom rhs pending env'
        result = rlhs `Result.andThen`
        \alhs -> rrhs `Result.andThen`
        \arhs -> case op of
          BArithmetic op -> VAtom `Result.map` arithApply op alhs arhs
          _ -> Err "TODO: eval binary op"
    in (result, env'')
  TList lcs -> (Ok <| VList lcs, env)
  TSheet sheet -> (Ok <| VSheet sheet, env)
  SheetWith sref arg ->
    let (rsheet, env') = evalSheet sref pending env
        result = rsheet `Result.andThen`
        \sheet -> Ok <| VSheet { sheet | input = arg }
    in (result, env')
  SheetInput sref ->
    let (rsheet, env') = evalSheet sref pending env
    in case rsheet of
      Err err -> (Err err, env')
      Ok sheet -> let (ratom, env'') = evalAtom sheet.output pending env'
                  in (VAtom `Result.map` ratom, env'')
  SheetOutput sref ->
    let (rsheet, env') = evalSheet sref pending env
    in case rsheet of
      Err err -> (Err err, env')
      Ok sheet -> let (ratom, env'') = evalAtom sheet.output pending env'
                  in (VAtom `Result.map` ratom, env'')
  _ -> (Err "TODO: eval term", env)

example0 = BinaryOp (BArithmetic (*)) (AFloat 4.1) (AInt 3)
(r0, exampleEnv0) = newTerm example0 envEmpty
example1 = BinaryOp (BArithmetic (+)) (AFloat 5) (ARef r0)
(r1, exampleEnv1) = newTerm example1 exampleEnv0
example2 = TList [LCElements [ARef r0, AString "and", ARef r1]]
(r2, exampleEnv2) = newTerm example2 exampleEnv1
example3 = Literal <| AString "example sheet"
(r3, exampleEnv3) = newTerm example3 exampleEnv2
example4 = TSheet { elements = [r3, r2]
                  , owned = Set.singleton r3
                  , input = AUnit
                  , output = ARef r3
                  }
(r4, exampleEnv4) = newTerm example4 exampleEnv3
example5 = SheetOutput r4
(r5, exampleEnv5) = newTerm example5 exampleEnv4
example6 = SheetWith r4 <| ARef r5
(r6, exampleEnv6) = newTerm example6 exampleEnv5
example = Literal <| ARef r6
test = eval example Set.empty exampleEnv6

{-
Notes:

new nodes
  mirror identical ref
  new ref wrapping another (default behavior)
  shallow copy of term head and locally-defined refs
    preserves subterm structure
    supports instantiation of procedural abstractions without local refs

example-oriented abstraction by extending sheets
  sheet structure
    parameters with arguments they're currently bound to
      can be thought of as publicly visible properties, and as example inputs
    encapsulated internal definitions, like a haskell where-clause
      likely provides most of a sheet's spatial workspace
      definitions are possibly labeled
    result body, which can refer to the encapsulated definitions
  operations
    with: replace some arguments; arguments may be added even if unused
      need a convenient way to support keyword args for descriptiveness
    input: retrieve arguments
    output: retrieve result
  ultimately all operations could use this approach
    primitives having opaque internals

multiple dormant alternative terms may live inside a ref entry

what is the right label structure to support auto-updating renamed identifiers?

pattern matching case analysis? at least simple boolean conditionals
  [sealed] algebraic data?

deletion, (partial)transferring dependencies

ref-counting gc (that can recognize embedded cycles)?

optional compositional visual representations provided by default?
  numbers
    points on a scale
    circular/rectangular areas
      bars a special case of this
    angles
    color
  numeric lists
    plotted on a chart: cartesian or polar coordinates
    vectors
    rectangular areas
    angular sweeps
  generic lists
    visualized change or difference
      juxtaposition
      superimposition
      deltas
      paths
      motion
    stat summaries
      brackets
      candlesticks
      histograms
-}

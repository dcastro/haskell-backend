{- |
Copyright   : (c) Runtime Verification, 2018-2021
License     : BSD-3-Clause
-}
module Kore.Simplify.Ceil (
    simplify,
    makeEvaluate,
    makeEvaluateTerm,
    simplifyEvaluated,
    Ceil (..),
) where

import Control.Error (
    MaybeT,
    maybeT,
 )
import Control.Monad.Reader (
    MonadReader,
 )
import Control.Monad.Reader qualified as Reader
import Data.Functor.Foldable qualified as Recursive
import Kore.Attribute.Symbol qualified as Attribute.Symbol (
    isTotal,
 )
import Kore.Attribute.Synthetic (
    synthesize,
 )
import Kore.Builtin.AssocComm.CeilSimplifier qualified as AssocComm
import Kore.Internal.Condition qualified as Condition
import Kore.Internal.Conditional (
    Conditional (..),
 )
import Kore.Internal.InternalList
import Kore.Internal.InternalMap
import Kore.Internal.InternalSet
import Kore.Internal.MultiAnd qualified as MultiAnd
import Kore.Internal.MultiOr qualified as MultiOr
import Kore.Internal.OrCondition (
    OrCondition,
 )
import Kore.Internal.OrCondition qualified as OrCondition
import Kore.Internal.OrPattern (
    OrPattern,
 )
import Kore.Internal.OrPattern qualified as OrPattern
import Kore.Internal.Pattern (
    Pattern,
 )
import Kore.Internal.Pattern qualified as Pattern
import Kore.Internal.Predicate (
    makeCeilPredicate,
 )
import Kore.Internal.Predicate qualified as Predicate
import Kore.Internal.SideCondition (
    SideCondition,
 )
import Kore.Internal.SideCondition qualified as SideCondition
import Kore.Internal.SideCondition.SideCondition qualified as SideCondition (
    Representation,
 )
import Kore.Internal.TermLike
import Kore.Rewrite.Function.Evaluator qualified as Axiom (
    evaluatePattern,
 )
import Kore.Rewrite.RewritingVariable (
    RewritingVariableName,
 )
import Kore.Simplify.AndPredicates qualified as And
import Kore.Simplify.CeilSimplifier
import Kore.Simplify.InjSimplifier
import Kore.Simplify.Simplify as Simplifier
import Kore.TopBottom
import Kore.Unparser (
    unparseToString,
 )
import Prelude.Kore

{- | Simplify a 'Ceil' of 'OrPattern'.

A ceil(or) is equal to or(ceil). We also take into account that
* ceil(top) = top
* ceil(bottom) = bottom
* ceil leaves predicates and substitutions unchanged
* ceil transforms terms into predicates
-}
simplify ::
    MonadSimplify simplifier =>
    SideCondition RewritingVariableName ->
    Ceil sort (OrPattern RewritingVariableName) ->
    simplifier (OrCondition RewritingVariableName)
simplify
    sideCondition
    Ceil{ceilChild = child} =
        simplifyEvaluated sideCondition child

{- | 'simplifyEvaluated' evaluates a ceil given its child, see 'simplify'
for details.
-}
simplifyEvaluated ::
    MonadSimplify simplifier =>
    SideCondition RewritingVariableName ->
    OrPattern RewritingVariableName ->
    simplifier (OrCondition RewritingVariableName)
simplifyEvaluated sideCondition child =
    OrPattern.traverseOr (makeEvaluate sideCondition) child

{- | Evaluates a ceil given its child as an Pattern, see 'simplify'
for details.
-}
makeEvaluate ::
    MonadSimplify simplifier =>
    SideCondition RewritingVariableName ->
    Pattern RewritingVariableName ->
    simplifier (OrCondition RewritingVariableName)
makeEvaluate sideCondition child
    | Pattern.isTop child = return OrCondition.top
    | Pattern.isBottom child = return OrCondition.bottom
    | isTop term = return $ OrCondition.fromCondition condition
    | otherwise = do
        termCeil <- makeEvaluateTerm childSort sideCondition term
        And.simplifyEvaluatedMultiPredicate
            sideCondition
            (MultiAnd.make [MultiOr.make [condition], termCeil])
  where
    (term, condition) = Pattern.splitTerm child
    childSort = Pattern.patternSort child

-- TODO: Ceil(function) should be an and of all the function's conditions, both
-- implicit and explicit.

-- | Evaluates the ceil of a TermLike, see 'simplify' for details.
makeEvaluateTerm ::
    forall simplifier.
    MonadSimplify simplifier =>
    Sort ->
    SideCondition RewritingVariableName ->
    TermLike RewritingVariableName ->
    simplifier (OrCondition RewritingVariableName)
makeEvaluateTerm resultSort sideCondition ceilChild =
    runCeilSimplifierWith
        ceilSimplifier
        sideCondition
        Ceil
            { ceilResultSort = resultSort
            , ceilOperandSort = termLikeSort ceilChild
            , ceilChild
            }
        & maybeT (makeSimplifiedCeil sideCondition Nothing ceilChild) return
  where
    ceilSimplifier =
        mconcat
            [ newPredicateCeilSimplifier
            , newDefinedCeilSimplifier sideCondition
            , -- We must apply user-defined \ceil rule before built-in rules
              -- because they may be more specific. In particular, Map and Set
              -- \ceil conditions are reduced to Bool expressions using in_keys.
              newAxiomCeilSimplifier
            , newApplicationCeilSimplifier
            , newBuiltinCeilSimplifier resultSort
            , newInjCeilSimplifier
            ]

newPredicateCeilSimplifier ::
    Monad simplifier =>
    CeilSimplifier
        simplifier
        (TermLike RewritingVariableName)
        (OrCondition RewritingVariableName)
newPredicateCeilSimplifier = CeilSimplifier $ \input ->
    case Predicate.makePredicate (ceilChild input) of
        Left _ -> empty
        Right predicate -> return (OrCondition.fromPredicate predicate)

newDefinedCeilSimplifier ::
    Monad simplifier =>
    SideCondition RewritingVariableName ->
    CeilSimplifier
        simplifier
        (TermLike RewritingVariableName)
        (OrCondition RewritingVariableName)
newDefinedCeilSimplifier sideCondition = CeilSimplifier $ \input ->
    if SideCondition.isDefined sideCondition (ceilChild input)
        then return OrCondition.top
        else empty

newApplicationCeilSimplifier ::
    MonadReader (SideCondition RewritingVariableName) simplifier =>
    MonadSimplify simplifier =>
    InternalVariable RewritingVariableName =>
    CeilSimplifier
        simplifier
        (TermLike RewritingVariableName)
        (OrCondition RewritingVariableName)
newApplicationCeilSimplifier = CeilSimplifier $ \input ->
    case ceilChild input of
        App_ patternHead children
            | let headAttributes = symbolAttributes patternHead
              , Attribute.Symbol.isTotal headAttributes -> do
                sideCondition <- Reader.ask
                let mkChildCeil =
                        makeEvaluateTermCeil
                            sideCondition
                simplifiedChildren <- mapM mkChildCeil children
                let ceils = simplifiedChildren
                And.simplifyEvaluatedMultiPredicate
                    sideCondition
                    (MultiAnd.make ceils)
        _ -> empty

newInjCeilSimplifier ::
    MonadReader (SideCondition RewritingVariableName) simplifier =>
    MonadSimplify simplifier =>
    CeilSimplifier
        simplifier
        (TermLike RewritingVariableName)
        (OrCondition RewritingVariableName)
newInjCeilSimplifier = CeilSimplifier $ \input ->
    case ceilChild input of
        Inj_ inj -> do
            InjSimplifier{evaluateCeilInj} <- askInjSimplifier
            sideCondition <- Reader.ask
            input{ceilChild = inj}
                & evaluateCeilInj
                & ceilChild
                & makeEvaluateTermCeil sideCondition
        _ -> empty

newBuiltinCeilSimplifier ::
    MonadReader (SideCondition RewritingVariableName) simplifier =>
    MonadSimplify simplifier =>
    Sort ->
    CeilSimplifier
        simplifier
        (TermLike RewritingVariableName)
        (OrCondition RewritingVariableName)
newBuiltinCeilSimplifier ceilSort = CeilSimplifier $ \input ->
    case ceilChild input of
        InternalList_ internal -> do
            sideCondition <- Reader.ask
            makeEvaluateInternalList ceilSort sideCondition internal
        InternalMap_ internalMap -> do
            sideCondition <- Reader.ask
            makeEvaluateInternalMap ceilSort sideCondition internalMap
        InternalSet_ internalSet -> do
            sideCondition <- Reader.ask
            makeEvaluateInternalSet ceilSort sideCondition internalSet
        _ -> empty

newAxiomCeilSimplifier ::
    MonadReader (SideCondition RewritingVariableName) simplifier =>
    MonadSimplify simplifier =>
    CeilSimplifier
        simplifier
        (TermLike RewritingVariableName)
        (OrCondition RewritingVariableName)
newAxiomCeilSimplifier = CeilSimplifier $ \input -> do
    sideCondition <- Reader.ask
    evaluation <-
        Axiom.evaluatePattern
            sideCondition
            Condition.top
            (synthesize $ CeilF input)
            (const empty)
    return (OrPattern.map toCondition evaluation)
  where
    toCondition Conditional{term = Top_ _, predicate, substitution} =
        Conditional{term = (), predicate, substitution}
    toCondition patt =
        error
            ( "Ceil simplification is expected to result ai a predicate, but"
                ++ " got ("
                ++ show patt
                ++ ")."
                ++ " The most likely cases are: evaluating predicate symbols, "
                ++ " and predicate symbols are currently unrecognized as such, "
                ++ "and programming errors."
            )

makeEvaluateInternalMap ::
    forall simplifier.
    MonadSimplify simplifier =>
    Sort ->
    SideCondition RewritingVariableName ->
    InternalMap Key (TermLike RewritingVariableName) ->
    MaybeT simplifier (OrCondition RewritingVariableName)
makeEvaluateInternalMap resultSort sideCondition internalMap =
    runCeilSimplifierWith
        AssocComm.newMapCeilSimplifier
        sideCondition
        Ceil
            { ceilResultSort = resultSort
            , ceilOperandSort = builtinAcSort
            , ceilChild = internalMap
            }
  where
    InternalAc{builtinAcSort} = internalMap

-- | Evaluates the ceil of a domain value.
makeEvaluateInternalSet ::
    forall simplifier.
    MonadSimplify simplifier =>
    Sort ->
    SideCondition RewritingVariableName ->
    InternalSet Key (TermLike RewritingVariableName) ->
    MaybeT simplifier (OrCondition RewritingVariableName)
makeEvaluateInternalSet resultSort sideCondition internalSet =
    runCeilSimplifierWith
        AssocComm.newSetCeilSimplifier
        sideCondition
        Ceil
            { ceilResultSort = resultSort
            , ceilOperandSort = builtinAcSort
            , ceilChild = internalSet
            }
  where
    InternalAc{builtinAcSort} = internalSet

makeEvaluateInternalList ::
    forall simplifier.
    MonadSimplify simplifier =>
    Sort ->
    SideCondition RewritingVariableName ->
    InternalList (TermLike RewritingVariableName) ->
    simplifier (OrCondition RewritingVariableName)
makeEvaluateInternalList listSort sideCondition internal = do
    children <- mapM (makeEvaluateTerm listSort sideCondition) (toList internal)
    let ceils :: [OrCondition RewritingVariableName]
        ceils = children
    And.simplifyEvaluatedMultiPredicate sideCondition (MultiAnd.make ceils)

{- | This handles the case when we can't simplify a term's ceil.

It returns the ceil of that term.

When the term's ceil implies the ceils of its subterms, this also @and@s
the subterms' simplified ceils to the result. This is needed because the
SMT solver can't infer a subterm's ceil from a term's ceil, so we
have to provide that information.

As an example, if we call @makeSimplifiedCeil@ for @f(g(x))@, and we don't
know how to simplify @ceil(g(x))@, the return value will be
@and(ceil(f(g(x))), ceil(g(x)))@.
-}
makeSimplifiedCeil ::
    MonadSimplify simplifier =>
    SideCondition RewritingVariableName ->
    Maybe SideCondition.Representation ->
    TermLike RewritingVariableName ->
    simplifier (OrCondition RewritingVariableName)
makeSimplifiedCeil
    sideCondition
    maybeCurrentCondition
    termLike@(Recursive.project -> _ :< termLikeF) =
        do
            childCeils <-
                if needsChildCeils
                    then mapM (makeEvaluateTerm ceilSort sideCondition) (toList termLikeF)
                    else return []
            And.simplifyEvaluatedMultiPredicate
                sideCondition
                (MultiAnd.make (unsimplified : childCeils))
      where
        ceilSort = termLikeSort termLike
        needsChildCeils = case termLikeF of
            ApplyAliasF _ -> False
            EndiannessF _ -> True
            SignednessF _ -> True
            AndF _ -> True
            ApplySymbolF _ -> True
            InjF _ -> True
            CeilF _ -> unexpectedError
            EqualsF _ -> unexpectedError
            ExistsF _ -> False
            IffF _ -> False
            ImpliesF _ -> False
            InF _ -> False
            NotF _ -> False
            BottomF _ -> unexpectedError
            DomainValueF _ -> True
            FloorF _ -> False
            ForallF _ -> False
            InhabitantF _ -> False
            MuF _ -> False
            NuF _ -> False
            NextF _ -> True
            OrF _ -> False
            RewritesF _ -> False
            TopF _ -> unexpectedError
            StringLiteralF _ -> unexpectedError
            InternalBoolF _ -> unexpectedError
            InternalBytesF _ -> unexpectedError
            InternalIntF _ -> unexpectedError
            InternalListF _ -> True
            InternalMapF _ -> True
            InternalSetF _ -> True
            InternalStringF _ -> unexpectedError
            VariableF _ -> False

        unsimplified =
            OrCondition.fromPredicate
                . Predicate.markSimplifiedMaybeConditional maybeCurrentCondition
                . makeCeilPredicate
                $ termLike

        ~unexpectedError =
            error ("Unexpected term type: " ++ unparseToString termLike)

{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Wallet.Primitive.Migration.SelectionSpec
    where

import Prelude

import Cardano.Wallet.Primitive.Migration.Selection
    ( RewardWithdrawal (..)
    , Selection (..)
    , SelectionCorrectness (..)
    , SelectionError (..)
    , SelectionFullError (..)
    , TxSize (..)
    , addValueToOutputs
    , check
    , create
    , extend
    , minimizeFee
    , minimizeFeeStep
    )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (..) )
import Cardano.Wallet.Primitive.Types.Hash
    ( Hash (..) )
import Cardano.Wallet.Primitive.Types.TokenBundle
    ( Flat (..), TokenBundle (..) )
import Cardano.Wallet.Primitive.Types.TokenMap
    ( AssetId (..), TokenMap )
import Cardano.Wallet.Primitive.Types.TokenPolicy
    ( TokenName (..), TokenPolicyId (..) )
import Cardano.Wallet.Primitive.Types.TokenQuantity
    ( TokenQuantity (..) )
import Cardano.Wallet.Primitive.Types.Tx
    ( TxConstraints (..)
    , txOutputCoinCost
    , txOutputCoinMinimum
    , txOutputCoinSize
    , txOutputHasValidSize
    , txOutputHasValidTokenQuantities
    )
import Control.Monad
    ( replicateM )
import Data.ByteArray.Encoding
    ( Base (Base16), convertToBase )
import Data.ByteString
    ( ByteString )
import Data.Either
    ( isRight )
import Data.Functor
    ( (<&>) )
import Data.Generics.Internal.VL.Lens
    ( view )
import Data.Generics.Labels
    ()
import Data.List.NonEmpty
    ( NonEmpty (..) )
import Data.Maybe
    ( fromMaybe )
import Data.Semigroup
    ( mtimesDefault, stimes )
import Fmt
    ( pretty )
import Numeric.Natural
    ( Natural )
import Test.Hspec
    ( Spec, describe, it )
import Test.Hspec.Core.QuickCheck
    ( modifyMaxSuccess )
import Test.Hspec.Extra
    ( parallel )
import Test.QuickCheck
    ( Arbitrary (..)
    , Blind (..)
    , Gen
    , Property
    , checkCoverage
    , choose
    , conjoin
    , counterexample
    , cover
    , elements
    , frequency
    , genericShrink
    , oneof
    , property
    , suchThat
    , suchThatMap
    , vector
    , withMaxSuccess
    , (===)
    )

import qualified Cardano.Wallet.Primitive.Types.Coin as Coin
import qualified Cardano.Wallet.Primitive.Types.TokenBundle as TokenBundle
import qualified Cardano.Wallet.Primitive.Types.TokenMap as TokenMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as B8
import qualified Data.Foldable as F
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

spec :: Spec
spec = describe "Cardano.Wallet.Primitive.Migration.SelectionSpec" $

    modifyMaxSuccess (const 1000) $ do

    parallel $ describe "Creating selections" $ do

        it "prop_create" $
            property prop_create

    parallel $ describe "Extending selections" $ do

        it "prop_extend" $
            property prop_extend

    parallel $ describe "Adding value to outputs" $ do

        it "prop_addValueToOutputs" $
            property prop_addValueToOutputs

    parallel $ describe "Minimizing fees" $ do

        it "prop_minimizeFee" $
            property prop_minimizeFee
        it "prop_minimizeFeeStep" $
            property prop_minimizeFeeStep

    parallel $ describe "Constraint calculations" $ do

        it "prop_txOutputCost" $
            property prop_txOutputCost
        it "prop_txOutputSize" $
            property prop_txOutputSize

--------------------------------------------------------------------------------
-- Creating a selection
--------------------------------------------------------------------------------

type MockSelection = Selection MockInputId MockSize
type MockSelectionError = SelectionError MockSize
type MockSelectionResult = Either MockSelectionError MockSelection

data ArgsForCreate = ArgsForCreate
    { mockConstraints :: MockTxConstraints
    , mockInputs :: NonEmpty (MockInputId, TokenBundle)
    , mockRewardWithdrawal :: Coin
    } deriving (Eq, Show)

instance Arbitrary ArgsForCreate where
    arbitrary = genArgsForCreate

genArgsForCreate :: Gen ArgsForCreate
genArgsForCreate = do
    mockConstraints <- genMockTxConstraints
    mockRewardWithdrawal <- oneof
        [ pure (Coin 0)
        , genCoinRange (Coin 1) (Coin 1_000_000)
        ]
    inputCount <- choose (1, 32)
    mockInputs <- (:|)
        <$> genMockInput mockConstraints
        <*> replicateM (inputCount - 1) (genMockInput mockConstraints)
    pure ArgsForCreate
        { mockConstraints
        , mockInputs
        , mockRewardWithdrawal
        }

prop_create :: ArgsForCreate -> Property
prop_create args =
    checkCoverage $
    cover 40 (resultIsSelection result)
        "Success" $
    cover 10 (resultHasZeroFeeExcess result)
        "Success with zero fee excess" $
    cover 1 (resultHasInsufficientAda result)
        "Failure due to insufficient ada" $
    cover 1 (resultIsFull result)
        "Failure due to oversized selection" $
    case result of
        Left SelectionAdaInsufficient ->
            property True
        Left (SelectionFull e) ->
            property (selectionSizeMaximum e < selectionSizeRequired e)
        Right selection ->
            check constraints selection === SelectionCorrect
  where
    ArgsForCreate
        { mockConstraints
        , mockInputs
        , mockRewardWithdrawal
        } = args
    constraints = unMockTxConstraints mockConstraints
    result = create constraints
        (RewardWithdrawal mockRewardWithdrawal)
        (mockInputs)

resultIsSelection :: MockSelectionResult -> Bool
resultIsSelection = isRight

resultHasZeroFeeExcess :: MockSelectionResult -> Bool
resultHasZeroFeeExcess = matchRight $ \selection ->
    feeExcess selection == Coin 0

resultHasInsufficientAda :: MockSelectionResult -> Bool
resultHasInsufficientAda = matchLeft $ \case
    SelectionAdaInsufficient -> True
    _ -> False

resultIsFull :: MockSelectionResult -> Bool
resultIsFull = matchLeft $ \case
    SelectionFull _ -> True
    _ -> False

--------------------------------------------------------------------------------
-- Extending a selection
--------------------------------------------------------------------------------

data ArgsForExtend = ArgsForExtend
    { mockConstraints :: MockTxConstraints
    , mockSelection :: MockSelection
    , mockInput :: (MockInputId, TokenBundle)
    } deriving (Eq, Show)

instance Arbitrary ArgsForExtend where
    arbitrary = genArgsForExtend

genArgsForExtend :: Gen ArgsForExtend
genArgsForExtend = genInner `suchThatMap` id
  where
    genInner = do
        ArgsForCreate {mockConstraints, mockInputs, mockRewardWithdrawal}
            <- genArgsForCreate
        let constraints = unMockTxConstraints mockConstraints
        mockInput <- (,)
            <$> genMockInputId
            <*> oneof
                [ genTokenBundleMixed mockConstraints
                  -- In order to increase coverage of error conditions,
                  -- deliberately include some large bundles whose ada
                  -- quantities are below the minimum:
                , TokenBundle (Coin 0) . F.fold <$>
                    replicateM 4 (genTokenMap mockConstraints)
                ]
        let maybeSelection = create constraints
                (RewardWithdrawal mockRewardWithdrawal) mockInputs
        pure $ case maybeSelection of
            Left _ -> Nothing
            Right mockSelection -> Just ArgsForExtend
                { mockConstraints
                , mockSelection
                , mockInput
                }

prop_extend :: ArgsForExtend -> Property
prop_extend args =
    checkCoverage $
    cover 40 (resultIsSelection result)
        "Success" $
    cover 10 (resultHasZeroFeeExcess result)
        "Success with zero fee excess" $
    cover 0.1 (resultHasInsufficientAda result)
        "Failure due to insufficient ada" $
    cover 0.1 (resultIsFull result)
        "Failure due to oversized selection" $
    case result of
        Left SelectionAdaInsufficient ->
            property True
        Left (SelectionFull e) ->
            property (selectionSizeMaximum e < selectionSizeRequired e)
        Right selection ->
            check constraints selection === SelectionCorrect
  where
    ArgsForExtend
        { mockConstraints
        , mockSelection
        , mockInput
        } = args
    constraints = unMockTxConstraints mockConstraints
    result = extend constraints mockSelection mockInput

--------------------------------------------------------------------------------
-- Adding value to outputs
--------------------------------------------------------------------------------

data ArgsForAddValueToOutputs = ArgsForAddValueToOutputs
    { mockConstraints :: MockTxConstraints
    , mockOutputs :: NonEmpty TokenMap
    }

instance Arbitrary ArgsForAddValueToOutputs where
    arbitrary = genArgsForAddValueToOutputs

genArgsForAddValueToOutputs :: Gen ArgsForAddValueToOutputs
genArgsForAddValueToOutputs = do
    mockConstraints <- genMockTxConstraints
    -- The upper limit is chosen to be comfortably greater than the maximum
    -- number of inputs we can typically fit into a transaction:
    mockOutputCount <- choose (1, 128)
    mockOutputs <- (:|)
        <$> genTokenMap mockConstraints
        <*> replicateM (mockOutputCount - 1) (genTokenMap mockConstraints)
    pure ArgsForAddValueToOutputs {..}

prop_addValueToOutputs :: Blind ArgsForAddValueToOutputs -> Property
prop_addValueToOutputs mockArgs =
    withMaxSuccess 100 $
    conjoinMap
        [ ( "Value is preserved"
          , F.fold result == F.fold mockOutputs )
        , ( "All outputs have valid sizes (if ada maximized)"
          , all (txOutputHasValidSizeWithMaxAda constraints) result )
        , ( "All outputs have valid token quantities"
          , all (txOutputHasValidTokenQuantities constraints) result )
        ]
  where
    Blind ArgsForAddValueToOutputs
        { mockConstraints
        , mockOutputs
        } = mockArgs
    constraints = unMockTxConstraints mockConstraints
    result :: NonEmpty TokenMap
    result = F.foldl'
        (addValueToOutputs constraints . NE.toList)
        (addValueToOutputs constraints [] (NE.head mockOutputs))
        (NE.tail mockOutputs)

txOutputHasValidSizeWithMaxAda
    :: Ord s => TxConstraints s -> TokenMap -> Bool
txOutputHasValidSizeWithMaxAda constraints b =
    txOutputHasValidSize constraints $ TokenBundle maxBound b

--------------------------------------------------------------------------------
-- Minimizing fees
--------------------------------------------------------------------------------

data ArgsForMinimizeFee = ArgsForMinimizeFee
    { mockConstraints :: MockTxConstraints
    , mockFeeExcessToMinimize :: Coin
    , mockOutputs :: NonEmpty TokenBundle
    }
    deriving (Eq, Show)

instance Arbitrary ArgsForMinimizeFee where
    arbitrary = genArgsForMinimizeFee

genArgsForMinimizeFee :: Gen ArgsForMinimizeFee
genArgsForMinimizeFee = do
    mockConstraints <- genMockTxConstraints
    mockOutputCount <- choose (1, 10)
    mockOutputs <- (:|)
        <$> genTokenBundleMixed mockConstraints
        <*> replicateM
            (mockOutputCount - 1)
            (genTokenBundleMixed mockConstraints)
    mockFeeExcessToMinimize <- genCoinRange (Coin 0) (Coin 10_000)
    pure ArgsForMinimizeFee
        { mockConstraints
        , mockFeeExcessToMinimize
        , mockOutputs
        }

prop_minimizeFee :: Blind ArgsForMinimizeFee -> Property
prop_minimizeFee mockArgs =
    checkCoverage $
    cover 50 (feeExcessAfter == Coin 0)
        "feeExcessAfter == 0" $
    cover 50 (totalOutputCostIncrease > Coin 0)
        "totalOutputCostIncrease > 0" $
    conjoin
        [ length outputsAfter == length outputsBefore
        , feeExcessAfter <= feeExcessBefore
        , totalOutputCostIncrease <> totalOutputAdaIncrease ==
            feeExcessReduction
        ]
  where
    Blind ArgsForMinimizeFee
        { mockConstraints
        , mockFeeExcessToMinimize
        , mockOutputs
        } = mockArgs
    constraints = unMockTxConstraints mockConstraints

    (feeExcessAfter, outputsAfter) =
        minimizeFee constraints (mockFeeExcessToMinimize, mockOutputs)
    feeExcessBefore =
        mockFeeExcessToMinimize
    feeExcessReduction =
        Coin.distance feeExcessBefore feeExcessAfter
    outputsBefore =
        mockOutputs

    totalOutputAdaAfter =
        F.foldMap (view #coin) outputsAfter
    totalOutputAdaBefore =
        F.foldMap (view #coin) outputsBefore
    totalOutputAdaIncrease =
        Coin.distance totalOutputAdaAfter totalOutputAdaBefore

    totalOutputCostAfter =
        F.foldMap (txOutputCost constraints) outputsAfter
    totalOutputCostBefore =
        F.foldMap (txOutputCost constraints) outputsBefore
    totalOutputCostIncrease =
        Coin.distance totalOutputCostBefore totalOutputCostAfter

--------------------------------------------------------------------------------
-- Minimizing fees (a single step)
--------------------------------------------------------------------------------

data ArgsForMinimizeFeeStep = ArgsForMinimizeFeeStep
    { mockConstraints :: MockTxConstraints
    , mockFeeExcessToMinimize :: Coin
    , mockOutput :: TokenBundle
    }
    deriving (Eq, Show)

instance Arbitrary ArgsForMinimizeFeeStep where
    arbitrary = genArgsForMinimizeFeeStep

genArgsForMinimizeFeeStep :: Gen ArgsForMinimizeFeeStep
genArgsForMinimizeFeeStep = do
    mockConstraints <- genMockTxConstraints
    mockOutput <- genTokenBundleMixed mockConstraints
    mockFeeExcessToMinimize <- genCoinRange (Coin 0) (Coin 1000)
    pure ArgsForMinimizeFeeStep
        { mockConstraints
        , mockFeeExcessToMinimize
        , mockOutput
        }

prop_minimizeFeeStep :: Blind ArgsForMinimizeFeeStep -> Property
prop_minimizeFeeStep mockArgs =
    checkCoverage $
    cover 50 (feeExcessAfter == Coin 0)
        "feeExcessAfter == 0" $
    cover 0.01 (feeExcessAfter /= Coin 0)
        "feeExcessAfter /= 0" $
    cover 1 (outputCostIncrease > Coin 0)
        "outputCostIncrease > 0" $
    counterexample counterexampleText $ conjoinMap
        [ ( "feeExcessAfter > feeExcessBefore"
          , feeExcessAfter <= feeExcessBefore )
        , ( "outputCoinAfter < outputCoinBefore"
          , outputCoinAfter >= outputCoinBefore )
        , ( "outputCostAfter < outputCostBefore"
          , outputCostAfter >= outputCostBefore )
        , ( "feeExcessReduction <> feeExcessAfter /= feeExcessBefore"
          , feeExcessReduction <> feeExcessAfter == feeExcessBefore )
        , ( "costOfEliminatingFeeExcess < gainOfEliminatingFeeExcess"
          , costOfEliminatingFeeExcess >= gainOfEliminatingFeeExcess )
        ]
  where
    Blind ArgsForMinimizeFeeStep
        { mockConstraints
        , mockFeeExcessToMinimize
        , mockOutput
        } = mockArgs
    constraints = unMockTxConstraints mockConstraints

    (feeExcessAfter, outputAfter) =
        minimizeFeeStep constraints (mockFeeExcessToMinimize, mockOutput)

    costOfEliminatingFeeExcess = Coin.distance
        (txOutputCoinCost constraints outputCoinAfter)
        (txOutputCoinCost constraints (outputCoinAfter <> feeExcessAfter))
    gainOfEliminatingFeeExcess = fromMaybe (Coin 0) $ Coin.subtractCoin
        feeExcessAfter
        costOfEliminatingFeeExcess

    feeExcessBefore =
        mockFeeExcessToMinimize
    feeExcessReduction =
        Coin.distance feeExcessBefore feeExcessAfter

    outputBefore =
        mockOutput
    outputCoinAfter =
        view #coin outputAfter
    outputCoinBefore =
        view #coin mockOutput
    outputCoinIncrease =
        Coin.distance outputCoinBefore outputCoinAfter
    outputCostAfter =
        txOutputCost constraints outputAfter
    outputCostBefore =
        txOutputCost constraints outputBefore
    outputCostIncrease =
        Coin.distance outputCostBefore outputCostAfter

    counterexampleText = counterexampleMap
        [ ( "costOfEliminatingFeeExcess"
          , show costOfEliminatingFeeExcess )
        , ( "gainOfEliminatingFeeExcess"
          , show gainOfEliminatingFeeExcess )
        , ( "feeExcessAfter"
          , show feeExcessAfter )
        , ( "feeExcessBefore"
          , show feeExcessBefore )
        , ( "feeExcessReduction"
          , show feeExcessReduction )
        , ( "outputCoinAfter"
          , show outputCoinAfter )
        , ( "outputCoinBefore"
          , show outputCoinBefore )
        , ( "outputCoinIncrease"
          , show outputCoinIncrease )
        , ( "outputCostAfter"
          , show outputCostAfter )
        , ( "outputCostBefore"
          , show outputCostBefore )
        , ( "outputCostIncrease"
          , show outputCostIncrease )
        ]

--------------------------------------------------------------------------------
-- Cost calculations
--------------------------------------------------------------------------------

-- TODO:
--
-- Find a way to merge the common parts of cost and size calculations.
-- Find a way to test the effect increasing the size of a token quantity.
-- Find a way to test that the largest possible bundle has a cost that does
-- not exceed maxBound :: Word64.

data ArgsForTxOutputCost = ArgsForTxOutputCost
    { mockConstraints :: MockTxConstraints
    , mockOutput :: TokenBundle
    } deriving (Eq, Show)

instance Arbitrary ArgsForTxOutputCost where
    arbitrary = genArgsForTxOutputCost

genArgsForTxOutputCost :: Gen ArgsForTxOutputCost
genArgsForTxOutputCost = do
    mockConstraints <- genMockTxConstraints
    mockOutput <- genTokenBundleMixed mockConstraints
    pure ArgsForTxOutputCost {..}

prop_txOutputCost :: ArgsForTxOutputCost -> Property
prop_txOutputCost mockArgs = conjoinMap
    [ ( "multiplying a coin by a factor of 10 increases its cost"
      , txOutputCost constraints mockOutput <
        txOutputCost constraints outputWithLargerCoin )
    , ( "all coins cost less than the maximum ada quantity"
      , txOutputCost constraints mockOutput <
        txOutputCost constraints outputWithMaxCoin )
    , ( "coin cost difference is independent of whether bundles are considered"
      , Coin.distance
            (txOutputCost constraints mockOutput)
            (txOutputCost constraints outputWithLargerCoin)
        ==
        Coin.distance
            (txOutputCoinCost constraints (view #coin mockOutput))
            (txOutputCoinCost constraints (view #coin outputWithLargerCoin))
      )
    ]
  where
    outputWithLargerCoin = TokenBundle.setCoin mockOutput
        $ multiplyCoinByTen
        $ TokenBundle.getCoin mockOutput
    outputWithMaxCoin =
        TokenBundle.setCoin mockOutput maxBound
    ArgsForTxOutputCost
        { mockConstraints
        , mockOutput
        } = mockArgs
    constraints =
        unMockTxConstraints mockConstraints
    multiplyCoinByTen (Coin n) = Coin $ 10 * n

--------------------------------------------------------------------------------
-- Size calculations
--------------------------------------------------------------------------------

data ArgsForTxOutputSize = ArgsForTxOutputSize
    { mockConstraints :: MockTxConstraints
    , mockOutput :: TokenBundle
    } deriving (Eq, Show)

instance Arbitrary ArgsForTxOutputSize where
    arbitrary = genArgsForTxOutputSize

genArgsForTxOutputSize :: Gen ArgsForTxOutputSize
genArgsForTxOutputSize = do
    mockConstraints <- genMockTxConstraints
    mockOutput <- genTokenBundleMixed mockConstraints
    pure ArgsForTxOutputSize {..}

prop_txOutputSize :: ArgsForTxOutputSize -> Property
prop_txOutputSize mockArgs = conjoinMap
    [ ( "multiplying a coin by a factor of 10 increases its size"
      , txOutputSize constraints mockOutput <
        txOutputSize constraints outputWithLargerCoin )
    , ( "all coins have sizes that are smaller than the maximum ada quantity"
      , txOutputSize constraints mockOutput <
        txOutputSize constraints outputWithMaxCoin )
    , ( "coin size difference is independent of whether bundles are considered"
      , txSizeDistance
            (txOutputSize constraints mockOutput)
            (txOutputSize constraints outputWithLargerCoin)
        ==
        txSizeDistance
            (txOutputCoinSize constraints (view #coin mockOutput))
            (txOutputCoinSize constraints (view #coin outputWithLargerCoin))
      )
    ]
  where
    outputWithLargerCoin = TokenBundle.setCoin mockOutput
        $ multiplyCoinByTen
        $ TokenBundle.getCoin mockOutput
    outputWithMaxCoin =
        TokenBundle.setCoin mockOutput maxBound
    ArgsForTxOutputSize
        { mockConstraints
        , mockOutput
        } = mockArgs
    constraints =
        unMockTxConstraints mockConstraints
    multiplyCoinByTen (Coin n) = Coin $ 10 * n

--------------------------------------------------------------------------------
-- Mock transaction constraints
--------------------------------------------------------------------------------

data MockTxConstraints = MockTxConstraints
    { mockTxCostFunction
        :: MockTxCostFunction
    , mockTxBaseSize
        :: MockTxBaseSize
    , mockTxInputSize
        :: MockTxInputSize
    , mockTxOutputMaximumSize
        :: MockTxOutputMaximumSize
    , mockTxOutputMaximumTokenQuantity
        :: MockTxOutputMaximumTokenQuantity
    , mockTxOutputMinimumAdaQuantity
        :: MockTxOutputMinimumAdaQuantity
    , mockTxMaximumSize
        :: MockTxMaximumSize
    }
    deriving (Eq, Show)

instance Arbitrary MockTxConstraints where
    arbitrary = genMockTxConstraints

genMockTxConstraints :: Gen MockTxConstraints
genMockTxConstraints = do
    mockTxCostFunction <- genMockTxCostFunction
    mockTxBaseSize <- genMockTxBaseSize
    mockTxInputSize <- genMockTxInputSize
    mockTxOutputMaximumSize <- genMockTxOutputMaximumSize
    mockTxOutputMaximumTokenQuantity <- genMockTxOutputMaximumTokenQuantity
    mockTxOutputMinimumAdaQuantity <- genMockTxOutputMinimumAdaQuantity
    mockTxMaximumSize <- genMockTxMaximumSize
        mockTxBaseSize
        mockTxInputSize
        mockTxOutputMaximumSize
    pure MockTxConstraints {..}

unMockTxConstraints :: MockTxConstraints -> TxConstraints MockSize
unMockTxConstraints MockTxConstraints {..} = TxConstraints
    { txBaseCost =
        baseCost mockTxCostFunction
    , txBaseSize =
        unMockTxBaseSize mockTxBaseSize
    , txInputCost =
        mockSizeToCost $ unMockTxInputSize mockTxInputSize
    , txInputSize =
        unMockTxInputSize mockTxInputSize
    , txOutputCost =
        mockSizeToCost . mockOutputSize
    , txOutputSize =
        mockOutputSize
    , txOutputMaximumSize =
        unMockTxOutputMaximumSize mockTxOutputMaximumSize
    , txOutputMaximumTokenQuantity =
        unMockTxOutputMaximumTokenQuantity mockTxOutputMaximumTokenQuantity
    , txOutputMinimumAdaQuantity =
        unMockTxOutputMinimumAdaQuantity mockTxOutputMinimumAdaQuantity
    , txRewardWithdrawalCost =
        mockSizeToCost . mockRewardWithdrawalSize
    , txRewardWithdrawalSize =
        mockRewardWithdrawalSize
    , txMaximumSize =
        unMockTxMaximumSize mockTxMaximumSize
    }
  where
    mockOutputSize :: TokenBundle -> MockSize
    mockOutputSize (TokenBundle c m) = (<>)
        (MockSize $ fromIntegral $ BS.length $ pretty $ Flat m)
        (mockCoinSize c)

    mockRewardWithdrawalSize :: Coin -> MockSize
    mockRewardWithdrawalSize = \case
        Coin 0 -> MockSize 0
        Coin c -> mockCoinSize (Coin c)

    mockCoinSize :: Coin -> MockSize
    mockCoinSize = MockSize . fromIntegral . length . show

    mockSizeToCost :: MockSize -> Coin
    mockSizeToCost (MockSize s) =
        Coin $ fromIntegral $ fromIntegral a * s
      where
        Coin a = sizeCost mockTxCostFunction

--------------------------------------------------------------------------------
-- Mock transaction costs
--------------------------------------------------------------------------------

data MockTxCostFunction = MockTxCostFunction
    { baseCost :: Coin
    , sizeCost :: Coin
    }
    deriving stock (Eq, Show)

genMockTxCostFunction :: Gen MockTxCostFunction
genMockTxCostFunction = MockTxCostFunction
    <$> genCoinRange (Coin 0) (Coin 1000)
    <*> genCoinRange (Coin 1) (Coin 4)

--------------------------------------------------------------------------------
-- Mock base transaction sizes
--------------------------------------------------------------------------------

newtype MockTxBaseSize = MockTxBaseSize
    { unMockTxBaseSize :: MockSize }
    deriving stock Eq
    deriving Show via Natural

genMockTxBaseSize :: Gen MockTxBaseSize
genMockTxBaseSize = MockTxBaseSize <$> genMockSizeRange 0 1000

--------------------------------------------------------------------------------
-- Mock input sizes
--------------------------------------------------------------------------------

newtype MockTxInputSize = MockTxInputSize
    { unMockTxInputSize :: MockSize }
    deriving stock Eq
    deriving Show via Natural

genMockTxInputSize :: Gen MockTxInputSize
genMockTxInputSize = MockTxInputSize <$> genMockSizeRange 2 4

--------------------------------------------------------------------------------
-- Mock maximum output sizes
--------------------------------------------------------------------------------

newtype MockTxOutputMaximumSize = MockTxOutputMaximumSize
    { unMockTxOutputMaximumSize :: MockSize }
    deriving stock Eq
    deriving Show via Natural

genMockTxOutputMaximumSize :: Gen MockTxOutputMaximumSize
genMockTxOutputMaximumSize =
    -- Chosen so that the upper limit is around twice the unconstrained maximum
    -- size of token bundles generated by 'genTokenBundle'.
    pure $ MockTxOutputMaximumSize $ MockSize 400

--------------------------------------------------------------------------------
-- Mock maximum token quantities
--------------------------------------------------------------------------------

newtype MockTxOutputMaximumTokenQuantity = MockTxOutputMaximumTokenQuantity
    { unMockTxOutputMaximumTokenQuantity :: TokenQuantity }
    deriving stock Eq
    deriving Show via Natural

genMockTxOutputMaximumTokenQuantity :: Gen MockTxOutputMaximumTokenQuantity
genMockTxOutputMaximumTokenQuantity = MockTxOutputMaximumTokenQuantity <$>
    genTokenQuantityRange (TokenQuantity 500) (TokenQuantity 2000)

--------------------------------------------------------------------------------
-- Mock minimum ada quantities
--------------------------------------------------------------------------------

data MockTxOutputMinimumAdaQuantity = MockTxOutputMinimumAdaQuantity
    { perOutput :: Coin
    , perOutputAsset :: Coin
    }
    deriving (Eq, Show)

unMockTxOutputMinimumAdaQuantity
    :: MockTxOutputMinimumAdaQuantity
    -> (TokenMap -> Coin)
unMockTxOutputMinimumAdaQuantity mock m =
    let assetCount = Set.size $ TokenMap.getAssets m in
    perOutput mock
        <> mtimesDefault assetCount (perOutputAsset mock)

genMockTxOutputMinimumAdaQuantity :: Gen MockTxOutputMinimumAdaQuantity
genMockTxOutputMinimumAdaQuantity = MockTxOutputMinimumAdaQuantity
    <$> genCoinRange (Coin 4) (Coin 8)
    <*> genCoinRange (Coin 1) (Coin 2)

--------------------------------------------------------------------------------
-- Mock maximum transaction sizes
--------------------------------------------------------------------------------

newtype MockTxMaximumSize = MockTxMaximumSize
    { unMockTxMaximumSize :: MockSize }
    deriving stock Eq
    deriving Show via Natural

genMockTxMaximumSize
    :: MockTxBaseSize
    -> MockTxInputSize
    -> MockTxOutputMaximumSize
    -> Gen MockTxMaximumSize
genMockTxMaximumSize mockTxBaseSize mockTxInputSize mockTxOutputMaximumSize =
    pure $ genInner 4
  where
    genInner :: Int -> MockTxMaximumSize
    genInner multiplier = MockTxMaximumSize $ mconcat
        [ unMockTxBaseSize mockTxBaseSize
        , stimes multiplier (unMockTxInputSize mockTxInputSize)
        , stimes multiplier (unMockTxOutputMaximumSize mockTxOutputMaximumSize)
        ]

--------------------------------------------------------------------------------
-- Generating inputs
--------------------------------------------------------------------------------

newtype MockInputId = MockInputId
    { unMockInputId :: ByteString }
    deriving (Eq, Ord)

instance Show MockInputId where
    show = T.unpack . T.decodeUtf8 . convertToBase Base16 . unMockInputId

genMockInput :: MockTxConstraints -> Gen (MockInputId, TokenBundle)
genMockInput mockConstraints = (,)
    <$> genMockInputId
    <*> genTokenBundleMixed mockConstraints

genMockInputAdaOnly :: MockTxConstraints -> Gen (MockInputId, TokenBundle)
genMockInputAdaOnly mockConstraints = (,)
    <$> genMockInputId
    <*> (TokenBundle.fromCoin <$> genCoinMixed mockConstraints)

genMockInputId :: Gen MockInputId
genMockInputId = MockInputId . BS.pack <$> vector 8

--------------------------------------------------------------------------------
-- Generating coins, token bundles, token maps, and token quantities
--------------------------------------------------------------------------------

genCoinMixed :: MockTxConstraints -> Gen Coin
genCoinMixed mockConstraints = frequency
    [ (10, genCoinBelowMinimumAdaQuantity mockConstraints)
    , (40, genCoinAboveMinimumAdaQuantity mockConstraints)
    ]

genCoinAboveMinimumAdaQuantity :: MockTxConstraints -> Gen Coin
genCoinAboveMinimumAdaQuantity mockConstraints =
    genCoinRange
        (txOutputCoinMinimum constraints)
        (txOutputCoinMinimum constraints `scaleCoin` 1000)
  where
    constraints = unMockTxConstraints mockConstraints

genCoinBelowMinimumAdaQuantity :: MockTxConstraints -> Gen Coin
genCoinBelowMinimumAdaQuantity mockConstraints =
    genCoinRange
        (Coin 1)
        (Coin.distance (txOutputCoinMinimum constraints) (Coin 1))
  where
    constraints = unMockTxConstraints mockConstraints

genCoinRange :: Coin -> Coin -> Gen Coin
genCoinRange (Coin minCoin) (Coin maxCoin) =
    Coin . fromIntegral <$> choose (minCoin, maxCoin)

genTokenBundleMixed :: MockTxConstraints -> Gen TokenBundle
genTokenBundleMixed mockConstraints =
    genInner `suchThat` txOutputHasValidSize constraints
  where
    constraints = unMockTxConstraints mockConstraints

    genInner :: Gen TokenBundle
    genInner = frequency $ fmap (\g -> g mockConstraints) <$> distribution

    distribution :: [(Int, MockTxConstraints -> Gen TokenBundle)]
    distribution =
        [ (10, genCoinBelowMinimumAdaQuantity <&> fmap TokenBundle.fromCoin)
        , (40, genCoinAboveMinimumAdaQuantity <&> fmap TokenBundle.fromCoin)
        , (40, genTokenBundleWithMinimumAdaQuantity)
        , (10, genTokenBundleAboveMinimumAdaQuantity)
        ]

genTokenBundleWithMinimumAdaQuantity :: MockTxConstraints -> Gen TokenBundle
genTokenBundleWithMinimumAdaQuantity mockConstraints = do
    m <- genTokenMap mockConstraints
    let minAda = txOutputMinimumAdaQuantity constraints m
    pure $ TokenBundle minAda m
  where
    constraints = unMockTxConstraints mockConstraints

genTokenBundleAboveMinimumAdaQuantity :: MockTxConstraints -> Gen TokenBundle
genTokenBundleAboveMinimumAdaQuantity mockConstraints = do
    m <- genTokenMap mockConstraints
    let minAda = txOutputMinimumAdaQuantity constraints m
    c <- genCoinRange (minAda <> Coin 1) (minAda `scaleCoin` 1000)
    pure $ TokenBundle c m
  where
    constraints = unMockTxConstraints mockConstraints

genTokenMap :: MockTxConstraints -> Gen TokenMap
genTokenMap mockConstraints =
    genInner
        `suchThat` (txOutputHasValidSize constraints . (TokenBundle maxBound))
        `suchThat` (txOutputHasValidTokenQuantities constraints)
  where
    constraints = unMockTxConstraints mockConstraints

    genInner :: Gen TokenMap
    genInner = do
        assetCount <- choose (1, 4)
        TokenMap.fromFlatList <$> replicateM assetCount genAssetQuantity

    genAssetQuantity :: Gen (AssetId, TokenQuantity)
    genAssetQuantity = (,)
        <$> genAssetId
        <*> genTokenQuantityRange
            (TokenQuantity 1)
            (txOutputMaximumTokenQuantity constraints)

    genAssetId :: Gen AssetId
    genAssetId = elements mockAssetIds

genTokenQuantityRange :: TokenQuantity -> TokenQuantity -> Gen TokenQuantity
genTokenQuantityRange (TokenQuantity a) (TokenQuantity b) =
    TokenQuantity . fromIntegral @Integer
        <$> choose (fromIntegral a, fromIntegral b)

mockAssetIds :: [AssetId]
mockAssetIds =
    [ AssetId i n
    | i <- UnsafeTokenPolicyId . Hash . B8.singleton <$> ['0' .. '3']
    , n <- UnsafeTokenName . B8.singleton <$> ['0' .. '3']
    ]

--------------------------------------------------------------------------------
-- Mock sizes
--------------------------------------------------------------------------------

newtype MockSize = MockSize { unMockSize :: Natural }
    deriving stock (Eq, Ord)
    deriving Show via Natural

instance Semigroup MockSize where
    MockSize a <> MockSize b = MockSize (a + b)

instance Monoid MockSize where
    mempty = MockSize 0

instance TxSize MockSize where
    MockSize a `txSizeDistance` MockSize b
        | a >= b    = MockSize (a - b)
        | otherwise = MockSize (b - a)

genMockSizeRange :: Natural -> Natural -> Gen MockSize
genMockSizeRange minSize maxSize =
    MockSize . fromIntegral @Integer @Natural <$>
        choose (fromIntegral minSize, fromIntegral maxSize)

--------------------------------------------------------------------------------
-- Arbitrary instances
--------------------------------------------------------------------------------

instance Arbitrary a => Arbitrary (NonEmpty a) where
    arbitrary = (:|) <$> arbitrary <*> arbitrary
    shrink = genericShrink

--------------------------------------------------------------------------------
-- Internal types and functions
--------------------------------------------------------------------------------

conjoinMap :: [(String, Bool)] -> Property
conjoinMap = conjoin . fmap (uncurry counterexample)

counterexampleMap :: [(String, String)] -> String
counterexampleMap
    = mconcat
    . fmap (\(k, v) -> k <> ":\n" <> v <> "\n\n")

matchLeft :: (e -> Bool) -> Either e a -> Bool
matchLeft f result = case result of
    Right _ -> False
    Left x -> f x

matchRight :: (a -> Bool) -> Either e a -> Bool
matchRight f result = case result of
    Right x -> f x
    Left _ -> False

scaleCoin :: Coin -> Int -> Coin
scaleCoin (Coin c) s = Coin $ c * fromIntegral s

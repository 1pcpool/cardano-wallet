{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Wallet.Primitive.MigrationSpec
    where

import Prelude

import Cardano.Wallet.Primitive.Migration
    ( CategorizedUTxO (..)
    , MigrationPlan (..)
    , RewardBalance (..)
    , UTxOEntryCategory (..)
    , categorizeUTxOEntries
    , categorizeUTxOEntry
    , createPlan
    --, uncategorizeUTxOEntries
    , addValueToOutputs
    )
import Cardano.Wallet.Primitive.Migration.Selection
    ( Selection (..) )
import Cardano.Wallet.Primitive.Migration.SelectionSpec
    ( MockInputId
    , MockTxConstraints (..)
    , conjoinMap
    , counterexampleMap
    , genCoinRange
    , genMockInput
    , genMockTxConstraints
    , genTokenBundle
    , genTokenMap
    , unMockTxConstraints
    )
import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (..) )
import Cardano.Wallet.Primitive.Types.TokenBundle
    ( TokenBundle (..) )
import Cardano.Wallet.Primitive.Types.TokenMap
    ( TokenMap )
import Cardano.Wallet.Primitive.Types.Tx
    ( TxConstraints
    , txOutputHasValidSize
    , txOutputHasValidTokenQuantities
    )
import Control.Monad
    ( replicateM )
import Data.Either
    ( isLeft, isRight )
--import Data.Generics.Internal.VL.Lens
--    ( view )
import Data.Generics.Labels
    ()
import Data.List.NonEmpty
    ( NonEmpty (..) )
--import Data.Set
--    ( Set )
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
    , oneof
    , property
    , withMaxSuccess
    , (===)
    )

import qualified Cardano.Wallet.Primitive.Migration.Selection as Selection
import qualified Data.Foldable as F
import qualified Data.List.NonEmpty as NE
--import qualified Data.Set as Set

spec :: Spec
spec = describe "Cardano.Wallet.Primitive.MigrationSpec" $

    modifyMaxSuccess (const 1000) $ do

    parallel $ describe "Creating migration plans" $ do

        it "prop_createPlan" $
            property prop_createPlan

    parallel $ describe "Categorizing UTxO entries" $ do

        it "prop_categorizeUTxOEntry" $
            property prop_categorizeUTxOEntry

    parallel $ describe "Adding value to outputs" $ do

        it "prop_addValueToOutputs" $
            property prop_addValueToOutputs

--------------------------------------------------------------------------------
-- Creating migration plans
--------------------------------------------------------------------------------

data MockCreatePlanArguments = MockCreatePlanArguments
    { mockConstraints :: MockTxConstraints
    , mockInputs :: [(MockInputId, TokenBundle)]
    , mockRewardBalance :: Coin
    }
    deriving (Eq, Show)

instance Arbitrary MockCreatePlanArguments where
    arbitrary = genMockCreatePlanArguments

genMockCreatePlanArguments :: Gen MockCreatePlanArguments
genMockCreatePlanArguments = do
    mockConstraints <- genMockTxConstraints
    mockInputCount <- choose (32, 32)
    mockInputs <- replicateM mockInputCount (genMockInput mockConstraints)
    mockRewardBalance <- oneof
        [ pure (Coin 0)
        , genCoinRange (Coin 1) (Coin 1_000_000)
        ]
    pure MockCreatePlanArguments
        { mockConstraints
        , mockInputs
        , mockRewardBalance
        }

prop_createPlan :: Blind MockCreatePlanArguments -> Property
prop_createPlan mockArgs =
    -- TODO: check how many different types of entries are unselected.
    checkCoverage $
    counterexample counterexampleText $
    cover 0.1 (selectionCount == 1)
        "selectionCount == 1" $
    cover 0 (selectionCount == 2)
        "selectionCount == 2" $
    cover 0 (selectionCount == 3)
        "selectionCount == 3" $
    conjoin
        [ --inputIds === inputIdsSelected `Set.union` inputIdsNotSelected
          totalFee result === totalFeeExpected
        , initiators (unselected result) === []
        ]
  where
    Blind MockCreatePlanArguments
        { mockConstraints
        , mockInputs
        , mockRewardBalance
        } = mockArgs
    constraints = unMockTxConstraints mockConstraints
    result = createPlan constraints categorizedUTxO
        (RewardBalance mockRewardBalance)

    categorizedUTxO = categorizeUTxOEntries constraints mockInputs
{-
    inputIds :: Set MockInputId
    inputIds = Set.fromList (fst <$> mockInputs)

    inputIdsSelected :: Set MockInputId
    inputIdsSelected = Set.fromList
        [ i
        | s <- selections result
        , i <- NE.toList (view #inputIds s)
        ]

    inputIdsNotSelected :: Set MockInputId
    inputIdsNotSelected = Set.fromList
        $ fmap fst
        $ uncategorizeUTxOEntries
        $ unselected result
-}
    selectionCount = length (selections result)

    totalFeeExpected :: Coin
    totalFeeExpected = F.foldMap fee (selections result)

    counterexampleText = counterexampleMap
        [ ( "mockConstraints"
          , show mockConstraints )
        , ( "count of initiators available"
          , show (length $ initiators categorizedUTxO) )
        , ( "count of initiators not selected"
          , show (length $ initiators $ unselected result) )
        , ( "count of supporters available"
          , show (length $ supporters categorizedUTxO) )
        , ( "count of supporters not selected"
          , show (length $ supporters $ unselected result) )
        , ( "count of freeriders available"
          , show (length $ freeriders categorizedUTxO) )
        , ( "count of freeriders not selected"
          , show (length $ freeriders $ unselected result) )
        , ( "count of ignorables available"
          , show (length $ ignorables categorizedUTxO) )
        , ( "count of ignorables not selected"
          , show (length $ ignorables $ unselected result) )
        ]

--------------------------------------------------------------------------------
-- Categorizing UTxO entries
--------------------------------------------------------------------------------

data MockCategorizeUTxOEntryArguments = MockCategorizeUTxOEntryArguments
    { mockConstraints :: MockTxConstraints
    , mockEntry :: TokenBundle
    }
    deriving (Eq, Show)

instance Arbitrary MockCategorizeUTxOEntryArguments where
    arbitrary = genMockCategorizeUTxOEntryArguments

genMockCategorizeUTxOEntryArguments :: Gen MockCategorizeUTxOEntryArguments
genMockCategorizeUTxOEntryArguments = do
    mockConstraints <- genMockTxConstraints
    mockEntry <- genTokenBundle mockConstraints
    pure MockCategorizeUTxOEntryArguments {..}

prop_categorizeUTxOEntry :: MockCategorizeUTxOEntryArguments -> Property
prop_categorizeUTxOEntry mockArgs =
    checkCoverage $
    cover 8.0 (result == Initiator) "Initiator" $
    cover 8.0 (result == Supporter) "Supporter" $
    cover 8.0 (result == Freerider) "Freerider" $
    cover 0.4 (result == Ignorable) "Ignorable" $
    property
        $ selectionCreateExpectation
        $ Selection.create constraints (Coin 0) mockEntry [()]
  where
    MockCategorizeUTxOEntryArguments
        { mockConstraints
        , mockEntry
        } = mockArgs
    constraints = unMockTxConstraints mockConstraints
    result = categorizeUTxOEntry constraints mockEntry
    selectionCreateExpectation = case result of
        Initiator -> isRight
        Supporter -> isLeft
        Freerider -> isLeft
        Ignorable -> isLeft

--------------------------------------------------------------------------------
-- Adding value to outputs
--------------------------------------------------------------------------------

data MockAddValueToOutputsArguments = MockAddValueToOutputsArguments
    { mockConstraints :: MockTxConstraints
    , mockOutputs :: NonEmpty TokenMap
    }

instance Arbitrary MockAddValueToOutputsArguments where
    arbitrary = genMockAddValueToOutputsArguments

genMockAddValueToOutputsArguments :: Gen MockAddValueToOutputsArguments
genMockAddValueToOutputsArguments = do
    mockConstraints <- genMockTxConstraints
    -- The upper limit is chosen to be comfortably greater than the maximum
    -- number of inputs we can typically fit into a transaction:
    mockOutputCount <- choose (128, 128)
    mockOutputs <- (:|)
        <$> genTokenMap mockConstraints
        <*> replicateM (mockOutputCount - 1) (genTokenMap mockConstraints)
    pure MockAddValueToOutputsArguments {..}

prop_addValueToOutputs :: Blind MockAddValueToOutputsArguments -> Property
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
    Blind MockAddValueToOutputsArguments
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
-- Miscellaneous types and functions
--------------------------------------------------------------------------------

coinToInteger :: Coin -> Integer
coinToInteger = fromIntegral . unCoin

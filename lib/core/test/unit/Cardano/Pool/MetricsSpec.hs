{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
module Cardano.Pool.MetricsSpec (spec) where

import Prelude

import Cardano.Pool.Metrics
    ( Block (..), calculatePerformance, combineMetrics )
import Cardano.Wallet.Primitive.Types
    ( BlockHeader (..)
    , Coin (..)
    , EpochLength (..)
    , Hash (..)
    , PoolId (..)
    , PoolOwner (..)
    , PoolRegistrationCertificate (..)
    , SlotId (..)
    , flatSlot
    , fromFlatSlot
    )
import Data.Function
    ( (&) )
import Data.Map.Strict
    ( Map )
import Data.Quantity
    ( Quantity (..) )
import Data.Word
    ( Word32, Word64 )
import Test.Hspec
    ( Spec, describe, it, shouldBe )
import Test.QuickCheck
    ( Arbitrary (..)
    , NonNegative (..)
    , Property
    , checkCoverage
    , choose
    , classify
    , counterexample
    , cover
    , elements
    , frequency
    , property
    , vectorOf
    , (===)
    )
import Test.QuickCheck.Arbitrary.Generic
    ( genericArbitrary, genericShrink )

import qualified Data.ByteString.Char8 as B8
import qualified Data.Map.Strict as Map

spec :: Spec
spec = do
    describe "combineMetrics" $ do
        it "pools with no entry for productions are included"
            $ property prop_combineDefaults

        it "it fails if a block-producer is not in the stake distr"
            $ checkCoverage
            $ property prop_combineIsLeftBiased

    describe "calculatePerformances" $ do
        it "performances are always between 0 and 1"
            $ property prop_performancesBounded01

        describe "golden test cases" $ do
            performanceGoldens

    describe "monitorStakePools" $ do
        it "records all stake pool registrations in the database"
            $ property prop_trackRegistrations

{-------------------------------------------------------------------------------
                                Properties
-------------------------------------------------------------------------------}

prop_combineDefaults
    :: Map PoolId (Quantity "lovelace" Word64)
    -> Property
prop_combineDefaults mStake = do
    combineMetrics mStake Map.empty Map.empty
    ===
    Right (Map.map (, Quantity 0, 0) mStake)

-- | it fails if a block-producer or performance is not in the stake distr
prop_combineIsLeftBiased
    :: Map PoolId (Quantity "lovelace" Word64)
    -> Map PoolId (Quantity "block" Word64)
    -> Map PoolId Double
    -> Property
prop_combineIsLeftBiased mStake mProd mPerf =
    let
        shouldLeft = or
            [ not . Map.null $ Map.difference mProd mStake
            , not . Map.null $ Map.difference mPerf mStake
            ]
    in
    cover 10 shouldLeft "A pool without stake produced"
    $ cover 50 (not shouldLeft) "Successfully combined the maps"
    $ case combineMetrics mStake mProd mPerf of
        Left _ ->
            shouldLeft === True
        Right x ->
            Map.map (\(a,_,_) -> a) x === mStake
{-# HLINT ignore prop_combineIsLeftBiased "Use ||" #-}

-- | Performances are always positive numbers
prop_performancesBounded01
    :: Map PoolId (Quantity "lovelace" Word64)
    -> Map PoolId (Quantity "block" Word64)
    -> (NonNegative Int)
    -> Property
prop_performancesBounded01 mStake mProd (NonNegative emptySlots) =
    all (between 0 1) performances
    & counterexample (show performances)
    & classify (all (== 0) performances) "all null"
  where
    performances :: [Double]
    performances = Map.elems $ calculatePerformance slots mStake mProd

    slots :: Int
    slots = emptySlots +
        fromIntegral (Map.foldl (\y (Quantity x) -> (y + x)) 0 mProd)

    between :: Ord a => a -> a -> a -> Bool
    between inf sup x = x >= inf && x <= sup


performanceGoldens :: Spec
performanceGoldens = do
    it "50% stake, producing 8/8 blocks => performance=1.0" $ do
        let stake      = mkStake      [ (poolA, 1), (poolB, 1) ]
        let production = mkProduction [ (poolA, 8), (poolB, 0) ]
        let performances = calculatePerformance 8 stake production
        Map.lookup poolA performances `shouldBe` (Just 1)

    it "50% stake, producing 4/8 blocks => performance=1.0" $ do
        let stake      = mkStake      [ (poolA, 1), (poolB, 1) ]
        let production = mkProduction [ (poolA, 4), (poolB, 0) ]
        let performances = calculatePerformance 8 stake production
        Map.lookup poolA performances `shouldBe` (Just 1)

    it "50% stake, producing 2/8 blocks => performance=0.5" $ do
        let stake      = mkStake      [ (poolA, 1), (poolB, 1) ]
        let production = mkProduction [ (poolA, 2), (poolB, 0) ]
        let performances = calculatePerformance 8 stake production
        Map.lookup poolA performances `shouldBe` (Just 0.5)

    it "50% stake, producing 0/8 blocks => performance=0.0" $ do
        let stake      = mkStake      [ (poolA, 1), (poolB, 1) ]
        let production = mkProduction [ (poolA, 0), (poolB, 0) ]
        let performances = calculatePerformance 8 stake production
        Map.lookup poolA performances `shouldBe` (Just 0)
  where
    poolA = PoolId "athena"
    poolB = PoolId "nemesis"
    mkStake = Map.map Quantity . Map.fromList
    mkProduction = Map.map Quantity . Map.fromList

-- | A list of chunks of blocks to be served up by the mock network layer.
newtype RegistrationsTest = RegistrationsTest [[Block]]

-- TODO: this is a sketch of the test
--
-- The idea is to run monitorStakePools with an in-memory database and mock network layer.
--
-- The mock network layer serves up chunks of blocks from the testcase, which
-- contain registration certificates
--
-- It then asserts that the registration info in the database matches that of
-- the blocks of the test case.
prop_trackRegistrations :: RegistrationsTest -> Property
prop_trackRegistrations testCase = monadicIO $ do
    let tr = nullTracer -- fixme: also check logs

    ownership <- run $ do
        nl <- makeNetworkLayer testCase
        withDBLayer Nothing $ \db -> do
            handle (\ErrNetworkInvalid -> pure ()) $ monitorStakePools tr nl db
            let pids = poolIds testCase
            owners <- mapM (readStakePoolOwners db) pids
            pure $ zip owners pids

    monitor $ counterexample $ "Actual pool owners:   " <> show ownership
    monitor $ counterexample $ "Expected pool owners: " <> show expected

    assert (ownership == expected)
  where
    makeNetworkLayer :: RegistrationsTest -> IO (NetworkLayer IO t Block)
    makeNetworkLayer (RegistrationsTest blocks) = do
        blockVar <- newMVar blocks
        let getChunk = modifyMVar blockVar $ \case
                [] -> ([], Nothing)
                (b:bs) -> (bs, Just b)
        pure $ NetworkLayer
            { nextBlocks = \c -> exceptT $ getChunk >>= \case
                    Just bs -> pure $ Right $ RollForward c bs
                    Nothing -> pure $ Left $ ErrGetBlockNetworkUnreachable $ ErrNetworkInvalid "the test case has finished"
            , findIntersection = \_ -> pure Nothing
            , initCursor = \_ -> error "mock cursor"
            , cursorSlotId = \_ -> SlotId 0 0
            , networkTip = error "mock networkTip"
            , postTx = error "mock postTx"
            , staticBlockchainParameters = (error "mock genesis", error "mock BlockChainParameters")
            , stakeDistribution = pure $ pure (EpochNo 0, mempty)
            , getAccountBalance = error "mock getAccountBalance"
            }

    poolIds :: RegistrationsTest -> [(PoolId, [PoolOwner])]
    poolIds = error "todo"

{-------------------------------------------------------------------------------
                                 Arbitrary
-------------------------------------------------------------------------------}

instance Arbitrary BlockHeader where
    arbitrary = BlockHeader
        <$> arbitrary
        <*> arbitrary
        <*> arbitrary
        <*> arbitrary
    shrink = genericShrink

instance Arbitrary SlotId where
    arbitrary = fromFlatSlot epochLength <$> arbitrary
    shrink sl = fromFlatSlot epochLength <$> shrink (flatSlot epochLength sl)

-- | Epoch length used to generate arbitrary @SlotId@
epochLength :: EpochLength
epochLength = EpochLength 50

instance Arbitrary (Hash tag) where
    shrink _  = []
    arbitrary = Hash . B8.pack
        <$> vectorOf 8 (elements (['a'..'f'] ++ ['0'..'9']))

instance Arbitrary Block where
   arbitrary = genericArbitrary
   shrink = genericShrink

instance Arbitrary (Quantity "block" Word32) where
    arbitrary = Quantity . fromIntegral <$> (arbitrary @Word32)
    shrink (Quantity x) = map Quantity $ shrink x

instance Arbitrary (Quantity "block" Word64) where
    arbitrary = Quantity . fromIntegral <$> (arbitrary @Word32)
    shrink (Quantity x) = map Quantity $ shrink x

instance Arbitrary (Quantity "lovelace" Word64) where
    arbitrary = Quantity . fromIntegral . unLovelace <$> (arbitrary @Lovelace)
    shrink (Quantity x) = map Quantity $ shrink x

-- TODO: Move to a shared location for Arbitrary newtypes
newtype Lovelace = Lovelace { unLovelace :: Word64 }
instance Arbitrary Lovelace where
    shrink (Lovelace x) = map Lovelace $ shrink x
    arbitrary = do
        n <- choose (0, 100)
        Lovelace <$> frequency
            [ (8, return n)
            , (2, choose (minLovelace, maxLovelace))
            ]
      where
        minLovelace = fromIntegral . getCoin $ minBound @Coin
        maxLovelace = fromIntegral . getCoin $ maxBound @Coin

instance Arbitrary PoolId where
    shrink _  = []
    arbitrary = PoolId . B8.pack
        <$> elements [ "ares", "athena", "hades", "hestia", "nemesis" ]

instance Arbitrary PoolOwner where
    shrink _  = []
    arbitrary = PoolOwner . B8.singleton <$> elements ['a'..'e']

instance Arbitrary PoolRegistrationCertificate where
    arbitrary = PoolRegistrationCertificate <$> arbitrary <*> arbitrary
    shrink (PoolRegistrationCertificate p o) =
        uncurry PoolRegistrationCertificate <$> shrink (p, o)

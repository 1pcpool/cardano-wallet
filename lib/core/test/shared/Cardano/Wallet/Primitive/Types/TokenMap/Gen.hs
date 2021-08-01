{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Wallet.Primitive.Types.TokenMap.Gen
    ( genAssetId
    , genAssetIdLargeRange
    , genTokenMapSized
    , genTokenMapSmallRange
    , shrinkAssetId
    , shrinkTokenMapSmallRange
    , AssetIdF (..)
    ) where

import Cardano.Wallet.Prelude

import Cardano.Wallet.Primitive.Types.TokenMap
    ( AssetId (..), TokenMap )
import Cardano.Wallet.Primitive.Types.TokenPolicy.Gen
    ( genTokenName
    , genTokenNameLargeRange
    , genTokenPolicyId
    , genTokenPolicyIdLargeRange
    , shrinkTokenName
    , shrinkTokenPolicyId
    , testTokenNames
    , testTokenPolicyIds
    )
import Cardano.Wallet.Primitive.Types.TokenQuantity.Gen
    ( genTokenQuantity, shrinkTokenQuantity )
import Control.Monad
    ( replicateM )
import Data.List
    ( elemIndex )
import Data.Maybe
    ( fromMaybe )
import GHC.Generics
    ( Generic )
import Test.QuickCheck
    ( CoArbitrary (..)
    , Function (..)
    , Gen
    , choose
    , functionMap
    , oneof
    , resize
    , shrinkList
    , sized
    , variant
    )
import Test.QuickCheck.Extra
    ( shrinkInterleaved )

import qualified Cardano.Wallet.Primitive.Types.TokenMap as TokenMap

--------------------------------------------------------------------------------
-- Asset identifiers chosen from a range that depends on the size parameter
--------------------------------------------------------------------------------

genAssetId :: Gen AssetId
genAssetId = sized $ \size -> do
    -- Ideally, we want to choose asset identifiers from a range that scales
    -- /linearly/ with the size parameter.
    --
    -- However, since each asset identifier has /two/ components that are
    -- generated /separately/, naively combining the generators for these two
    -- components will give rise to a range of asset identifiers that scales
    -- /quadratically/ with the size parameter, which is /not/ what we want.
    --
    -- Therefore, we pass each individual generator a size parameter that
    -- is the square root of the original.
    --
    let sizeSquareRoot = max 1 $ ceiling $ sqrt $ fromIntegral @Int @Double size
    AssetId
        <$> resize sizeSquareRoot genTokenPolicyId
        <*> resize sizeSquareRoot genTokenName

shrinkAssetId :: AssetId -> [AssetId]
shrinkAssetId (AssetId p t) = uncurry AssetId <$> shrinkInterleaved
    (p, shrinkTokenPolicyId)
    (t, shrinkTokenName)

--------------------------------------------------------------------------------
-- Asset identifiers chosen from a large range (to minimize collisions)
--------------------------------------------------------------------------------

genAssetIdLargeRange :: Gen AssetId
genAssetIdLargeRange = AssetId
    <$> genTokenPolicyIdLargeRange
    <*> genTokenNameLargeRange

--------------------------------------------------------------------------------
-- Token maps with assets and quantities chosen from ranges that depend on the
-- size parameter
--------------------------------------------------------------------------------

genTokenMapSized :: Gen TokenMap
genTokenMapSized = sized $ \size -> do
    assetCount <- choose (0, size)
    TokenMap.fromFlatList <$> replicateM assetCount genAssetQuantity
  where
    genAssetQuantity = (,)
        <$> genAssetId
        <*> genTokenQuantity

--------------------------------------------------------------------------------
-- Token maps with assets and quantities chosen from small ranges
--------------------------------------------------------------------------------

genTokenMapSmallRange :: Gen TokenMap
genTokenMapSmallRange = do
    assetCount <- oneof
        [ pure 0
        , pure 1
        , choose (2, 16)
        ]
    TokenMap.fromFlatList <$> replicateM assetCount genAssetQuantity
  where
    genAssetQuantity = (,)
        <$> genAssetId
        <*> genTokenQuantity

shrinkTokenMapSmallRange :: TokenMap -> [TokenMap]
shrinkTokenMapSmallRange
    = fmap TokenMap.fromFlatList
    . shrinkList shrinkAssetQuantity
    . TokenMap.toFlatList
  where
    shrinkAssetQuantity (a, q) = shrinkInterleaved
        (a, shrinkAssetId)
        (q, shrinkTokenQuantity)

--------------------------------------------------------------------------------
-- Filtering functions
--------------------------------------------------------------------------------

newtype AssetIdF = AssetIdF AssetId
    deriving (Generic, Eq, Show, Read)

instance Function AssetIdF where
    function = functionMap show read

instance CoArbitrary AssetIdF where
    coarbitrary (AssetIdF AssetId{tokenName, tokenPolicyId}) genB = do
        let n = fromMaybe 0 (elemIndex tokenName testTokenNames)
        let m = fromMaybe 0 (elemIndex tokenPolicyId testTokenPolicyIds)
        variant (n+m) genB

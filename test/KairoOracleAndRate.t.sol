// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { KairoProtocolLens } from "../src/lens/KairoProtocolLens.sol";
import { KairoOracleRouter } from "../src/oracle/KairoOracleRouter.sol";
import { KairoTestBase } from "./helpers/KairoTestBase.sol";
import { MockPriceFeed } from "./mocks/MockPriceFeed.sol";

contract KairoOracleAndRateTest is KairoTestBase {
    function testRouterReturnsFreshPrimaryWithNormalizedSources() public {
        MockPriceFeed primary = new MockPriceFeed(8, "Primary", 100 * 1e8);
        MockPriceFeed fallbackFeed = new MockPriceFeed(18, "Fallback", 100.5 ether);
        KairoOracleRouter router =
            _router(address(primary), address(fallbackFeed), "Composite price");

        (uint256 price, uint256 updatedAt) = router.latestPrice();

        assertEq(price, 100 * 1e8);
        assertEq(updatedAt, block.timestamp);
        assertEq(router.decimals(), 8);
        assertEq(router.description(), "Composite price");
    }

    function testRouterReturnsFallbackWhenPrimaryIsStale() public {
        MockPriceFeed primary = new MockPriceFeed(8, "Primary", 100 * 1e8);
        MockPriceFeed fallbackFeed = new MockPriceFeed(18, "Fallback", 101 ether);
        KairoOracleRouter router =
            _router(address(primary), address(fallbackFeed), "Composite price");
        primary.setTimestamp(block.timestamp - 2 days);
        fallbackFeed.setPriceAndTimestamp(101 ether, block.timestamp);

        (uint256 price, uint256 updatedAt) = router.latestPrice();

        assertEq(price, 101 * 1e8);
        assertEq(updatedAt, block.timestamp);
    }

    function testRouterRejectsWhenEverySourceIsStale() public {
        MockPriceFeed primary = new MockPriceFeed(8, "Primary", 100 * 1e8);
        MockPriceFeed fallbackFeed = new MockPriceFeed(8, "Fallback", 100 * 1e8);
        KairoOracleRouter router =
            _router(address(primary), address(fallbackFeed), "Composite price");
        primary.setTimestamp(block.timestamp - 2 days);
        fallbackFeed.setTimestamp(block.timestamp - 2 days);

        vm.expectRevert(KairoOracleRouter.NoValidPrice.selector);
        router.latestPrice();
    }

    function testRouterRejectsPricesOutsideConfiguredDeviation() public {
        MockPriceFeed primary = new MockPriceFeed(8, "Primary", 100 * 1e8);
        MockPriceFeed fallbackFeed = new MockPriceFeed(8, "Fallback", 120 * 1e8);
        KairoOracleRouter router =
            _router(address(primary), address(fallbackFeed), "Composite price");

        vm.expectPartialRevert(KairoOracleRouter.SourcesDeviate.selector);
        router.latestPrice();
    }

    function testRateModelIsContinuousAtOptimalUtilization() public view {
        assertEq(rateModel.rateAtUtilization(0), BASE_RATE);
        assertEq(rateModel.rateAtUtilization(OPTIMAL_UTILIZATION), BASE_RATE + SLOPE_ONE);
        assertEq(rateModel.rateAtUtilization(RAY), BASE_RATE + SLOPE_ONE + SLOPE_TWO);
    }

    function testMarketRatesIncreaseAfterBorrowing() public {
        KairoProtocolLens.RateView memory beforeRates = lens.previewRates(address(usdc));
        _openPosition(100 ether, 100_000 * USDC_UNIT);
        KairoProtocolLens.RateView memory afterRates = lens.previewRates(address(usdc));

        assertEq(beforeRates.borrowRatePerSecondRay, BASE_RATE);
        assertEq(beforeRates.supplyRatePerSecondRay, 0);
        assertGt(afterRates.borrowRatePerSecondRay, beforeRates.borrowRatePerSecondRay);
        assertGt(afterRates.supplyRatePerSecondRay, beforeRates.supplyRatePerSecondRay);
    }
}

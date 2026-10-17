// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { KairoRiskPolicy } from "../src/governance/KairoRiskPolicy.sol";
import { DataTypes } from "../src/libraries/DataTypes.sol";

contract KairoRiskPolicyTest is Test {
    KairoRiskPolicy internal policy;

    function setUp() public {
        policy = new KairoRiskPolicy();
    }

    function testUnchangedConfigurationIsRoutine() public view {
        DataTypes.MarketConfig memory config = _config();
        KairoRiskPolicy.Assessment memory result = policy.assess(config, config, _bounds());

        assertTrue(result.structurallyValid);
        assertTrue(result.withinPolicy);
        assertEq(uint256(result.reviewTier), uint256(KairoRiskPolicy.ReviewTier.Routine));
        assertEq(result.changeFlags, 0);
        assertEq(result.liquidationGapBps, 1000);
        assertEq(result.borrowToSupplyCapBps, 8000);
    }

    function testLtvIncreaseRequiresRiskReview() public view {
        DataTypes.MarketConfig memory current = _config();
        DataTypes.MarketConfig memory proposed = _config();
        proposed.loanToValueBps = 7600;

        KairoRiskPolicy.Assessment memory result = policy.assess(current, proposed, _bounds());
        assertTrue(result.withinPolicy);
        assertEq(uint256(result.reviewTier), uint256(KairoRiskPolicy.ReviewTier.Risk));
        assertTrue(result.changeFlags & policy.FLAG_LTV_INCREASE() != 0);
    }

    function testCapIncreaseRequiresTreasuryReview() public view {
        DataTypes.MarketConfig memory current = _config();
        DataTypes.MarketConfig memory proposed = _config();
        proposed.supplyCap = 2_000_000;
        proposed.borrowCap = 1_500_000;

        KairoRiskPolicy.Assessment memory result = policy.assess(current, proposed, _bounds());
        assertTrue(result.withinPolicy);
        assertEq(uint256(result.reviewTier), uint256(KairoRiskPolicy.ReviewTier.Treasury));
        assertTrue(result.changeFlags & policy.FLAG_SUPPLY_CAP_INCREASE() != 0);
        assertTrue(result.changeFlags & policy.FLAG_BORROW_CAP_INCREASE() != 0);
    }

    function testSourceChangeRequiresGovernanceReview() public view {
        DataTypes.MarketConfig memory current = _config();
        DataTypes.MarketConfig memory proposed = _config();
        proposed.priceFeed = address(0xFEE1);

        KairoRiskPolicy.Assessment memory result = policy.assess(current, proposed, _bounds());
        assertEq(uint256(result.reviewTier), uint256(KairoRiskPolicy.ReviewTier.Governance));
        assertTrue(result.changeFlags & policy.FLAG_SOURCE_CHANGE() != 0);
    }

    function testOutOfPolicyConfigurationRequiresGovernanceReview() public view {
        DataTypes.MarketConfig memory current = _config();
        DataTypes.MarketConfig memory proposed = _config();
        proposed.loanToValueBps = 8200;
        proposed.liquidationThresholdBps = 8500;

        KairoRiskPolicy.Assessment memory result = policy.assess(current, proposed, _bounds());
        assertTrue(result.structurallyValid);
        assertFalse(result.withinPolicy);
        assertEq(uint256(result.reviewTier), uint256(KairoRiskPolicy.ReviewTier.Governance));
    }

    function testStructuralFailureIsReportedBeforePolicy() public view {
        DataTypes.MarketConfig memory current = _config();
        DataTypes.MarketConfig memory proposed = _config();
        proposed.borrowCap = proposed.supplyCap + 1;

        KairoRiskPolicy.Assessment memory result = policy.assess(current, proposed, _bounds());
        assertFalse(result.structurallyValid);
        assertFalse(result.withinPolicy);
        assertEq(uint256(result.reviewTier), uint256(KairoRiskPolicy.ReviewTier.Governance));
    }

    function testGovernanceReviewTakesPriorityOverRiskAndTreasury() public view {
        DataTypes.MarketConfig memory current = _config();
        DataTypes.MarketConfig memory proposed = _config();
        proposed.loanToValueBps = 7600;
        proposed.supplyCap = 2_000_000;
        proposed.borrowCap = 1_500_000;
        proposed.rateModel = address(0xA11CE);

        KairoRiskPolicy.Assessment memory result = policy.assess(current, proposed, _bounds());
        assertEq(uint256(result.reviewTier), uint256(KairoRiskPolicy.ReviewTier.Governance));
        assertTrue(result.changeFlags & policy.FLAG_LTV_INCREASE() != 0);
        assertTrue(result.changeFlags & policy.FLAG_SUPPLY_CAP_INCREASE() != 0);
        assertTrue(result.changeFlags & policy.FLAG_RATE_MODEL_CHANGE() != 0);
    }

    function testPolicyIdChangesWithBounds() public view {
        KairoRiskPolicy.PolicyBounds memory first = _bounds();
        KairoRiskPolicy.PolicyBounds memory second = _bounds();
        assertEq(policy.policyId(first), policy.policyId(second));
        second.maxLoanToValueBps -= 1;
        assertNotEq(policy.policyId(first), policy.policyId(second));
    }

    function testInvalidBoundsRevert() public {
        KairoRiskPolicy.PolicyBounds memory bounds = _bounds();
        bounds.maxBorrowToSupplyCapBps = 0;
        vm.expectRevert(KairoRiskPolicy.InvalidPolicyBounds.selector);
        policy.policyId(bounds);
    }

    function _config() internal pure returns (DataTypes.MarketConfig memory) {
        return DataTypes.MarketConfig({
            supplyToken: address(0x1001),
            priceFeed: address(0x1002),
            rateModel: address(0x1003),
            supplyCap: 1_000_000,
            borrowCap: 800_000,
            priceMaxAge: 1 hours,
            loanToValueBps: 7500,
            liquidationThresholdBps: 8500,
            liquidationBonusBps: 500,
            reserveFactorBps: 1000,
            closeFactorBps: 5000,
            assetDecimals: 6,
            status: DataTypes.MarketStatus.Active,
            borrowingEnabled: true
        });
    }

    function _bounds() internal pure returns (KairoRiskPolicy.PolicyBounds memory) {
        return KairoRiskPolicy.PolicyBounds({
            maxLoanToValueBps: 8250,
            minLiquidationGapBps: 500,
            maxLiquidationBonusBps: 1000,
            minReserveFactorBps: 500,
            maxCloseFactorBps: 6000,
            maxBorrowToSupplyCapBps: 8500,
            maxPriceAge: 2 hours
        });
    }
}

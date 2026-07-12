// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { KairoLendingPool } from "../src/KairoLendingPool.sol";
import { KairoConfigurator } from "../src/governance/KairoConfigurator.sol";
import { IKairoPoolView } from "../src/interfaces/IKairoPoolView.sol";
import { KairoProtocolLens } from "../src/lens/KairoProtocolLens.sol";
import { KairoRiskEngine } from "../src/risk/KairoRiskEngine.sol";
import { KairoTreasury } from "../src/treasury/KairoTreasury.sol";

/// @notice Deploys the Kairo core and wires operational roles.
contract DeployKairo is Script {
    struct Deployment {
        KairoLendingPool pool;
        KairoRiskEngine riskEngine;
        KairoProtocolLens lens;
        KairoConfigurator configurator;
        KairoTreasury treasury;
    }

    function run() external returns (Deployment memory deployed) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address finalAdmin = vm.envOr("KAIRO_ADMIN", deployer);
        address reserveRecipient = vm.envOr("KAIRO_RESERVE_RECIPIENT", finalAdmin);

        vm.startBroadcast(deployerKey);

        deployed.pool = new KairoLendingPool(deployer, deployer);
        deployed.riskEngine = new KairoRiskEngine(IKairoPoolView(address(deployed.pool)));
        deployed.lens = new KairoProtocolLens(IKairoPoolView(address(deployed.pool)));
        deployed.configurator = new KairoConfigurator(deployer, deployed.pool);
        deployed.treasury = new KairoTreasury(deployer, deployed.pool, reserveRecipient);

        deployed.pool.setRiskEngine(address(deployed.riskEngine));
        deployed.pool.setTreasury(address(deployed.treasury));
        deployed.pool.grantRole(deployed.pool.CONFIGURATOR_ROLE(), address(deployed.configurator));
        deployed.pool.grantRole(deployed.pool.GUARDIAN_ROLE(), address(deployed.configurator));

        if (finalAdmin != deployer) {
            deployed.pool.beginAdminTransfer(finalAdmin);
            deployed.configurator.beginAdminTransfer(finalAdmin);
            deployed.treasury.beginAdminTransfer(finalAdmin);
        }

        vm.stopBroadcast();

        console2.log("KairoLendingPool", address(deployed.pool));
        console2.log("KairoRiskEngine", address(deployed.riskEngine));
        console2.log("KairoProtocolLens", address(deployed.lens));
        console2.log("KairoConfigurator", address(deployed.configurator));
        console2.log("KairoTreasury", address(deployed.treasury));
        if (finalAdmin != deployer) {
            console2.log("Pending administrator", finalAdmin);
        }
    }
}


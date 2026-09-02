// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ReinsVault} from "./ReinsVault.sol";

/// @title ReinsFactory
/// @notice Deploys one cheap minimal-proxy vault per owner request. Every vault shares the same
///         implementation and price oracle; custody and policy state live in each clone.
contract ReinsFactory {
    address public immutable implementation;
    IPriceOracle public immutable oracle;

    mapping(address owner => address[]) private _vaultsOf;

    event VaultCreated(address indexed owner, address indexed vault);

    constructor(IPriceOracle oracle_) {
        oracle = oracle_;
        implementation = address(new ReinsVault());
    }

    function createVault() external returns (address vault) {
        vault = Clones.clone(implementation);
        ReinsVault(vault).initialize(msg.sender, oracle);
        _vaultsOf[msg.sender].push(vault);
        emit VaultCreated(msg.sender, vault);
    }

    function vaultsOf(address owner) external view returns (address[] memory) {
        return _vaultsOf[owner];
    }
}

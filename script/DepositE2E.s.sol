// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

interface IExchangeDeposit {
    function coldAddress() external view returns (address);
    function minimumInput() external view returns (uint256);
}

contract DepositE2E is Script {
    event Deposit(address indexed receiver, uint256 amount);

    function run() external {
        // anvil のデフォルトアカウント #0
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. コントラクトデプロイ
        ExchangeDepositSimple ed = new ExchangeDepositSimple(
            payable(makeAddr("cold")),
            payable(deployer)
        );
        console.log("ExchangeDeposit deployed:", address(ed));

        ProxySimple pf = new ProxySimple(payable(address(ed)));
        console.log("Proxy deployed:", address(pf));

        // 2. 入金TX
        (bool success,) = address(pf).call{value: 0.1 ether}("");
        require(success, "Deposit failed");
        console.log("Deposit TX sent: 0.1 ETH");

        vm.stopBroadcast();
    }
}

contract ExchangeDepositSimple {
    address payable public coldAddress;
    address public adminAddress;
    uint256 public minimumInput = 0.001 ether;
    address payable private immutable thisAddress;
    event Deposit(address indexed receiver, uint256 amount);

    constructor(address payable _cold, address _admin) {
        coldAddress = _cold;
        adminAddress = _admin;
        thisAddress = payable(address(this));
    }

    function getSendAddress() internal view returns (address payable) {
        if (thisAddress == address(this)) return coldAddress;
        return ExchangeDepositSimple(thisAddress).coldAddress();
    }

    receive() external payable {
        require(coldAddress != address(0), "dead");
        require(msg.value >= minimumInput, "Amount too small");
        (bool success,) = coldAddress.call{value: msg.value}("");
        require(success, "forward failed");
        emit Deposit(msg.sender, msg.value);
    }

    function gatherEth() external {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        (bool result,) = getSendAddress().call{value: balance}("");
        require(result, "gather failed");
    }
}

contract ProxySimple {
    address payable immutable target;
    constructor(address payable _target) { target = _target; }
    receive() external payable {
        (bool success,) = target.call{value: msg.value}("");
        require(success);
    }
    fallback() external payable {
        address impl = target;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

interface IExchangeDeposit {
    function coldAddress() external view returns (address);
    function minimumInput() external view returns (uint256);
}

contract DepositDetectionTest is Test {
    address constant EXCHANGE_DEPOSIT = 0x265c27C849B0E1a62636f6007e8a74dC2a2584Aa;
    address constant PROXY = 0xBB8580F17603cD1e8E3B1c0a952CC78a1A217c15;

    event Deposit(address indexed _sender, uint256 _value);

    function setUp() public {
        // テスト用にETHを付与
        vm.deal(address(this), 10 ether);
    }

    /// @notice 通常のETH入金でDepositイベントが出ることを確認
    function test_normalDeposit() public {
        uint256 depositAmount = 0.1 ether;

        vm.expectEmit(true, false, false, true, EXCHANGE_DEPOSIT);
        emit Deposit(PROXY, depositAmount);

        (bool success,) = PROXY.call{value: depositAmount}("");
        assertTrue(success, "Deposit should succeed");
    }

    /// @notice minimumInput未満の入金はリバートする
    function test_belowMinimumReverts() public {
        uint256 minInput = IExchangeDeposit(EXCHANGE_DEPOSIT).minimumInput();

        (bool success,) = PROXY.call{value: minInput - 1}("");
        assertFalse(success, "Below minimum should revert");
    }

    /// @notice coldAddressにETHが転送されることを確認
    function test_ethForwardedToCold() public {
        address cold = IExchangeDeposit(EXCHANGE_DEPOSIT).coldAddress();
        uint256 coldBefore = cold.balance;
        uint256 depositAmount = 0.1 ether;

        (bool success,) = PROXY.call{value: depositAmount}("");
        assertTrue(success);

        assertEq(cold.balance, coldBefore + depositAmount, "Cold should receive ETH");
    }

    /// @notice selfdestruct強制送金でDepositイベントは出ない
    function test_selfdestructNoEvent() public {
        vm.recordLogs();

        // selfdestructでProxyにETH強制送金
        ForceEthSender sender = new ForceEthSender{value: 0.01 ether}(payable(PROXY));

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Depositイベントが出てないことを確認
        bytes32 depositTopic = keccak256("Deposit(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != depositTopic,
                "Deposit event should not be emitted on selfdestruct"
            );
        }

        // ProxyにETHが残っていることを確認
        assertTrue(PROXY.balance > 0, "Proxy should have forced ETH");
    }

    /// @notice ERC20送金ではDepositイベントは出ない
    function test_erc20NoDepositEvent() public {
        vm.recordLogs();

        // ダミーERC20をデプロイしてProxyに送金
        DummyERC20 token = new DummyERC20();
        token.transfer(PROXY, 1000);

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // DepositイベントではなくTransferイベントだけ出ることを確認
        bytes32 depositTopic = keccak256("Deposit(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != depositTopic,
                "Deposit event should not be emitted on ERC20 transfer"
            );
        }
    }
}

/// @notice selfdestruct強制送金用コントラクト
contract ForceEthSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @notice テスト用の最小ERC20
contract DummyERC20 {
    mapping(address => uint256) public balanceOf;
    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor() {
        balanceOf[msg.sender] = 1_000_000;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// ExchangeDepositは0.6.11なので、インターフェースだけ定義してデプロイ済みバイトコードを使う
interface IExchangeDeposit {
    function coldAddress() external view returns (address);
    function minimumInput() external view returns (uint256);
    function changeMinInput(uint256 _newMin) external;
    function gatherEth() external;
}

interface IProxyFactory {
    function deployNewInstance(bytes32 salt) external returns (address);
    function mainAddress() external view returns (address);
}

contract DepositLocalTest is Test {
    address payable cold;
    address payable admin;
    IExchangeDeposit exchangeDeposit;
    IProxyFactory proxyFactory;
    address proxy;

    event Deposit(address indexed _sender, uint256 _value);

    function setUp() public {
        cold = payable(makeAddr("cold"));
        admin = payable(makeAddr("admin"));

        // ExchangeDeposit をデプロイ（0.6.11のバイトコードを直接使う）
        // deployCode はartifactからバイトコードを読むが、solcバージョンが違うのでvm.etcodeを使う
        // ここではforge create相当で、コンパイル済みバイトコードを取得して使う

        // 方法: Hardhatでコンパイル済みのartifactからバイトコードを取得
        // 今回はシンプルにSolidity 0.8でミニマル実装を書く
        ExchangeDepositMock edMock = new ExchangeDepositMock(cold, admin);
        exchangeDeposit = IExchangeDeposit(address(edMock));

        ProxyFactoryMock pfMock = new ProxyFactoryMock(payable(address(edMock)));
        proxyFactory = IProxyFactory(address(pfMock));

        // Proxyデプロイ
        proxy = proxyFactory.deployNewInstance(bytes32(uint256(1)));
    }

    /// @notice 通常のETH入金でDepositイベントが出る
    function test_normalDeposit() public {
        uint256 amount = 0.1 ether;
        vm.deal(address(this), amount);

        vm.expectEmit(true, false, false, true, address(exchangeDeposit));
        emit Deposit(proxy, amount);

        (bool success,) = proxy.call{value: amount}("");
        assertTrue(success);
    }

    /// @notice coldAddressにETHが転送される
    function test_ethForwardedToCold() public {
        uint256 amount = 0.1 ether;
        vm.deal(address(this), amount);
        uint256 coldBefore = cold.balance;

        (bool success,) = proxy.call{value: amount}("");
        assertTrue(success);

        assertEq(cold.balance, coldBefore + amount);
    }

    /// @notice minimumInput未満はリバート
    function test_belowMinimumReverts() public {
        uint256 minInput = exchangeDeposit.minimumInput();
        vm.deal(address(this), minInput);

        (bool success,) = proxy.call{value: minInput - 1}("");
        assertFalse(success);
    }

    /// @notice selfdestruct強制送金ではDepositイベント出ない
    function test_selfdestructNoEvent() public {
        vm.deal(address(this), 0.01 ether);
        vm.recordLogs();

        new ForceEthSender{value: 0.01 ether}(payable(proxy));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 depositTopic = keccak256("Deposit(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != depositTopic);
            }
        }
        assertTrue(proxy.balance > 0);
    }

    /// @notice gatherEthで強制送金分を回収できる
    function test_gatherEthRecovery() public {
        // まずselfdestructで強制送金
        vm.deal(address(this), 0.05 ether);
        new ForceEthSender{value: 0.05 ether}(payable(proxy));
        assertEq(proxy.balance, 0.05 ether);

        uint256 coldBefore = cold.balance;

        // gatherEthを呼ぶ（admin権限不要、誰でも呼べる）
        IExchangeDeposit(proxy).gatherEth();

        assertEq(proxy.balance, 0);
        assertEq(cold.balance, coldBefore + 0.05 ether);
    }

    /// @notice ERC20送金ではDepositイベント出ない
    function test_erc20NoDepositEvent() public {
        vm.recordLogs();

        DummyERC20 token = new DummyERC20();
        token.transfer(proxy, 1000);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 depositTopic = keccak256("Deposit(address,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != depositTopic);
            }
        }
    }

    /// @notice 複数Proxyが同じExchangeDepositにイベント集約される
    function test_multipleProxiesSameEvent() public {
        address proxy2 = proxyFactory.deployNewInstance(bytes32(uint256(2)));
        address proxy3 = proxyFactory.deployNewInstance(bytes32(uint256(3)));

        vm.deal(address(this), 1 ether);

        vm.recordLogs();

        (bool s1,) = proxy.call{value: 0.1 ether}("");
        (bool s2,) = proxy2.call{value: 0.2 ether}("");
        (bool s3,) = proxy3.call{value: 0.3 ether}("");
        assertTrue(s1 && s2 && s3);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 depositTopic = keccak256("Deposit(address,uint256)");

        uint256 depositCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == depositTopic) {
                // 全てExchangeDepositアドレスから出ていることを確認
                assertEq(logs[i].emitter, address(exchangeDeposit));
                depositCount++;
            }
        }
        assertEq(depositCount, 3);
    }

    receive() external payable {}
}

/// @notice ExchangeDepositの0.8互換ミニマル実装（実際のコントラクトと同じパターン）
contract ExchangeDepositMock {
    address payable public coldAddress;
    address public adminAddress;
    uint256 public minimumInput = 0.001 ether;
    /// @dev 実際と同様に、自身のアドレスをimmutableで保持してProxy判定に使う
    address payable private immutable thisAddress;

    event Deposit(address indexed _sender, uint256 _value);

    constructor(address payable _cold, address _admin) {
        coldAddress = _cold;
        adminAddress = _admin;
        thisAddress = payable(address(this));
    }

    function isExchangeDepositor() internal view returns (bool) {
        return thisAddress == address(this);
    }

    /// @dev Proxy経由ならSTATICCALLでExchangeDeposit本体のcoldAddressを取得
    function getSendAddress() internal view returns (address payable) {
        if (isExchangeDepositor()) {
            return coldAddress;
        } else {
            return ExchangeDepositMock(thisAddress).coldAddress();
        }
    }

    receive() external payable {
        require(coldAddress != address(0), "I am dead :-(");
        require(msg.value >= minimumInput, "Amount too small");
        (bool success,) = coldAddress.call{value: msg.value}("");
        require(success, "Forwarding funds failed");
        emit Deposit(msg.sender, msg.value);
    }

    function changeMinInput(uint256 _newMin) external {
        require(msg.sender == adminAddress, "Not admin");
        minimumInput = _newMin;
    }

    function gatherEth() external {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        (bool result,) = getSendAddress().call{value: balance}("");
        require(result, "Could not gather ETH");
    }
}

/// @notice ProxyFactoryのミニマル実装
contract ProxyFactoryMock {
    address payable public mainAddress;

    constructor(address payable _main) {
        mainAddress = _main;
    }

    function deployNewInstance(bytes32 salt) external returns (address) {
        bytes memory bytecode = abi.encodePacked(
            type(ProxyMock).creationCode,
            abi.encode(mainAddress)
        );
        address proxy;
        assembly {
            proxy := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(proxy) { revert(0, 0) }
        }
        return proxy;
    }
}

/// @notice Proxyのミニマル実装（CALL for ETH, DELEGATECALL for calldata）
contract ProxyMock {
    address payable immutable target;

    constructor(address payable _target) {
        target = _target;
    }

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

contract ForceEthSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

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

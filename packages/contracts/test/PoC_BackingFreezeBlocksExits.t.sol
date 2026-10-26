// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "src/CollateralVault.sol";

contract MockERC20 {
    string public name = "JPY";
    string public symbol = "JPY";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address _to, uint256 _amt) external { balanceOf[_to] += _amt; }
    function approve(address _s, uint256 _a) external returns (bool) { allowance[msg.sender][_s] = _a; return true; }
    function transfer(address _to, uint256 _a) external returns (bool) { balanceOf[msg.sender] -= _a; balanceOf[_to] += _a; return true; }
    function transferFrom(address _f, address _t, uint256 _a) external returns (bool) {
        allowance[_f][msg.sender] -= _a; balanceOf[_f] -= _a; balanceOf[_t] += _a; return true;
    }
}

contract MockDToken {
    address public vault;
    address public underlying;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _vault, address _underlying) { vault = _vault; underlying = _underlying; }

    function allowedUnderlying(address) external pure returns (bool) { return true; }
    function convertToUnderlying(uint256 _a) external pure returns (uint256) { return _a; }
    function convertToDToken(uint256 _a) external pure returns (uint256) { return _a; }
    function mint(address _to, uint256 _a) external { require(msg.sender == vault); totalSupply += _a; balanceOf[_to] += _a; }
    function burn(address _from, uint256 _a) external { require(msg.sender == vault); totalSupply -= _a; balanceOf[_from] -= _a; }
}

interface IVaultLike {
    function initialize(address, address, address, address) external;
    function addToWhitelist(address) external;
    function addStrategy(address, uint256, uint256) external;
    function allocate() external;
    function deposit(uint256) external returns (uint256);
    function redeem(uint256, address) external returns (uint256, uint256);
    function claim(uint256) external returns (uint256);
    function bufferBalance() external view returns (uint256);
    function backingRatioForPricing() external view returns (uint256, bool);
    function actualLiabilities() external view returns (uint256);
}

contract MockStrategy {
    address public underlying;
    uint256 public principal;

    constructor(address _underlying) { underlying = _underlying; }

    function setPrincipal(uint256 _p) external { principal = _p; }

    function deposit(uint256, uint256 _received) external returns (uint256) {
        principal += _received;
        return _received;
    }

    function estimatedTotalUnderlying() external view returns (uint256) { return principal; }

    function realizedYield() external pure returns (uint256) { return 0; }
    function sendToVault(uint256) external pure returns (uint256) { return 0; }
    function sendProfitToVault() external pure returns (uint256) { return 0; }
    function writeoffPrincipal(uint256) external pure returns (uint256) { return 0; }
    function sweepRewardToken(address, uint256) external pure returns (uint256) { return 0; }
}

/// @notice A single strategy loss freezes every user exit, including a matured
///         withdrawal request whose funds are already ring-fenced in the buffer.
contract PoCBackingFreezeBlocksExits is Test {
    MockERC20 jpy;
    MockDToken dToken;
    IVaultLike vault;
    MockStrategy strategy;
    address admin = address(0xAD);

    function setUp() public {
        vm.warp(1_700_000_000);
        jpy = new MockERC20();
        dToken = new MockDToken(address(0), address(jpy));

        CollateralVault impl = new CollateralVault();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");

        address vaultAddr = address(proxy);
        dToken = new MockDToken(vaultAddr, address(jpy));
        vault = IVaultLike(vaultAddr);

        vault.initialize(address(jpy), address(dToken), address(0xBE), admin);
        strategy = new MockStrategy(address(jpy));

        jpy.mint(address(this), 1_000e18);
        jpy.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e18);

        vm.startPrank(admin);
        vault.addToWhitelist(address(strategy));
        vault.addStrategy(address(strategy), 10_000, 1e30);
        vault.allocate();
        vm.stopPrank();
    }

    function testLossFreezesRedemptionsAndMaturedClaims() public {
        // Healthy: 200 underlying buffered (20%), 800 allocated.
        assertEq(vault.bufferBalance(), 200e18);
        assertEq(vault.actualLiabilities(), 1_000e18);

        // 1) Queue a withdrawal while solvency holds: 200 is paid from the buffer,
        //    the remaining 50 is queued. The dToken for it is already burned.
        (, uint256 requestId) = vault.redeem(250e18, address(this));
        assertGt(requestId, 0);
        assertEq(vault.bufferBalance(), 0);

        // 2) A second user deposits, refilling the buffer to 100.
        address bob = address(0xB0B);
        jpy.mint(bob, 100e18);
        vm.startPrank(bob);
        jpy.approve(address(vault), type(uint256).max);
        vault.deposit(100e18);
        vm.stopPrank();
        assertEq(vault.bufferBalance(), 100e18);

        // 3) 100 underlying of the strategy position is lost (12.5% of it).
        strategy.setPrincipal(700e18);
        uint256 ratio = _ratio();
        assertEq(ratio, 888888888888888888); // 800 assets / 900 liabilities

        // 4) The matured claim is paid out of the buffer and is ratio-neutral to
        //    ratio-improving, yet the pre-state ratio check rejects it.
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.BackingRatioBelowMinimum.selector, ratio, 1e18));
        vault.claim(requestId);
        assertGe(vault.bufferBalance(), 50e18, "the buffer could have covered the claim");

        // 5) A fresh small redemption is blocked too, although it also improves the ratio.
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.BackingRatioBelowMinimum.selector, ratio, 1e18));
        vault.redeem(10e18, address(this));

        // 6) And a fresh deposit is blocked, so users cannot recapitalize either.
        jpy.mint(address(this), 100e18);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.BackingRatioBelowMinimum.selector, ratio, 1e18));
        vault.deposit(100e18);
    }

    function _ratio() internal view returns (uint256 ratio) {
        (ratio,) = vault.backingRatioForPricing();
    }

    /// @notice The gate has no deadband: a 1 wei valuation shortfall blocks a
    ///         deposit that would itself repay it.
    function testOneWeiShortfallAlsoBlocksDeposit() public {
        strategy.setPrincipal(800e18 - 1); // 999...999 assets vs 1_000e18 liabilities
        uint256 ratio = _ratio();
        assertEq(ratio, 999999999999999999);

        jpy.mint(address(this), 1e18);
        vm.expectRevert(abi.encodeWithSelector(CollateralVault.BackingRatioBelowMinimum.selector, ratio, 1e18));
        vault.deposit(1);
    }
}

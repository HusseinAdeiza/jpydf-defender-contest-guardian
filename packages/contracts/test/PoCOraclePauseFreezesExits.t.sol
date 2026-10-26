// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import "src/AddressesRegistry.sol";
import "src/ActivePool.sol";
import "src/BorrowerOperations.sol";
import "src/CollSurplusPool.sol";
import "src/DefaultPool.sol";
import "src/GasPool.sol";
import "src/JPYdfTroveNFT.sol";
import "src/JpydfToken.sol";
import "src/SortedTroves.sol";
import "src/StabilityPool.sol";
import "src/TroveManager.sol";

/// @notice A permanent oracle outage latches only the reversible pause, and nothing escalates it to the
///         shutdown state, so closeTrove (the one exit that needs no amount price) stays blocked and
///         shutdown() itself no-ops on the failing quote. Pre-delta code shut the branch down on the first
///         failure, which made closes price-free.
contract MockColl is ERC20 {
    constructor() ERC20("Mock Coll", "MOCK") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    receive() external payable {
        _mint(msg.sender, msg.value);
    }
}

contract MockFeed is IPriceFeed {
    uint256 public price = 1e18;
    bool public failing;

    function setFailing(bool _failing) external {
        failing = _failing;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function fetchPrice() external view returns (uint256, bool) {
        return (price, failing);
    }

    function fetchRedemptionPrice() external view returns (uint256, bool) {
        return (price, failing);
    }

    function fetchUrgentRedemptionPrice() external view returns (uint256, bool) {
        return (price, failing);
    }

    function lastGoodPrice() external view returns (uint256) {
        return price;
    }
}

contract Stub {
    function ping() external {}
}

contract StubMetadata {
    function uri(IMetadataNFT.TroveData memory) external pure returns (string memory) {
        return "";
    }
}

contract PoCOraclePauseFreezesExits is Test {
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");
    Stub bridgeAdmin;

    MockColl coll;
    MockWETH weth;
    MockFeed feed;
    JpydfToken jpydf;
    AddressesRegistry reg;

    BorrowerOperations bo;
    TroveManager tm;

    function setUp() public {
        coll = new MockColl();
        weth = new MockWETH();
        feed = new MockFeed();
        bridgeAdmin = new Stub();
        vm.deal(address(this), 1 ether);
        jpydf = new JpydfToken(owner, address(bridgeAdmin), true);

        // deploy-time-finalized branch: constructor-only validation, no finalizer
        reg = new AddressesRegistry(owner, 1.3e18, 1.2e18, 0.1e18, 1.15e18, 5e16, 10e16, address(0));

        StubMetadata metadataNFT = new StubMetadata();
        Stub interestRouter = new Stub();
        Stub hintHelpers = new Stub();
        Stub multiTroveGetter = new Stub();
        Stub collateralRegistry = new Stub();

        uint256 nonce = vm.getNonce(address(this));
        address activePool = vm.computeCreateAddress(address(this), nonce);
        address defaultPool = vm.computeCreateAddress(address(this), nonce + 1);
        address sortedTroves = vm.computeCreateAddress(address(this), nonce + 2);
        address gasPool = vm.computeCreateAddress(address(this), nonce + 3);
        address collSurplusPool = vm.computeCreateAddress(address(this), nonce + 4);
        address troveNFT = vm.computeCreateAddress(address(this), nonce + 5);
        address troveManager = vm.computeCreateAddress(address(this), nonce + 6);
        address stabilityPool = vm.computeCreateAddress(address(this), nonce + 7);

        IAddressesRegistry.AddressVars memory v;
        v.collToken = IERC20Metadata(address(coll));
        v.borrowerOperations = IBorrowerOperations(address(0));
        v.troveManager = ITroveManager(troveManager);
        v.troveNFT = ITroveNFT(troveNFT);
        v.metadataNFT = IMetadataNFT(address(metadataNFT));
        v.stabilityPool = IStabilityPool(stabilityPool);
        v.priceFeed = IPriceFeed(address(feed));
        v.activePool = IActivePool(activePool);
        v.defaultPool = IDefaultPool(defaultPool);
        v.gasPoolAddress = gasPool;
        v.collSurplusPool = ICollSurplusPool(collSurplusPool);
        v.sortedTroves = ISortedTroves(sortedTroves);
        v.interestRouter = IInterestRouter(address(interestRouter));
        v.hintHelpers = IHintHelpers(address(hintHelpers));
        v.multiTroveGetter = IMultiTroveGetter(address(multiTroveGetter));
        v.collateralRegistry = ICollateralRegistry(address(collateralRegistry));
        v.jpydfToken = IJpydfToken(address(jpydf));
        v.WETH = IWETH(address(weth));

        address borrowerOperations = vm.computeCreateAddress(address(this), nonce + 8);
        v.borrowerOperations = IBorrowerOperations(borrowerOperations);

        vm.prank(owner);
        reg.setAddresses(v);

        // deploy in the predicted order
        new ActivePool(reg);
        new DefaultPool(reg);
        new SortedTroves(reg);
        new GasPool(reg);
        new CollSurplusPool(reg);
        new JPYdfTroveNFT(reg);
        tm = new TroveManager(reg, 2e18);
        new StabilityPool(reg);
        bo = new BorrowerOperations(reg);

        vm.prank(owner);
        jpydf.setBranchAddresses(address(tm), stabilityPool, address(bo), activePool);

        coll.mint(user, 400_000e18);
        coll.mint(user2, 400_000e18);
        weth.mint(user, 1 ether);
        weth.mint(user2, 1 ether);
        vm.startPrank(user);
        coll.approve(address(bo), type(uint256).max);
        weth.approve(address(bo), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(user2);
        coll.approve(address(bo), type(uint256).max);
        weth.approve(address(bo), type(uint256).max);
        vm.stopPrank();
    }

    function _open2() internal returns (uint256 troveId) {
        vm.startPrank(user2);
        troveId = bo.openTrove(user2, 0, 300_000e18, 100_000e18, 0, 0, 1e16, type(uint256).max, user2, address(0), address(0));
        vm.stopPrank();
    }

    function _fund() internal {
        vm.prank(address(bo));
        jpydf.mint(user, 200_000e18);
        vm.prank(user);
        jpydf.approve(address(bo), type(uint256).max);
    }

    function _open(uint256 _debt) internal returns (uint256 troveId) {
        vm.startPrank(user);
        troveId = bo.openTrove(user, 0, 300_000e18, _debt, 0, 0, 1e16, type(uint256).max, user, address(0), address(0));
        vm.stopPrank();
    }

    function testOutageLatchesAPauseAndBlocksEveryExit() public {
        uint256 troveId = _open(100_000e18);
        _open2();
        _fund();

        // the oracle fails: a real feed/proxy pair turns this into isOracleFailureShutdown == true
        feed.setFailing(true);

        // 1. the only collateral exit reverts
        vm.prank(user);
        vm.expectRevert(BorrowerOperations.NewOracleFailureDetected.selector);
        bo.closeTrove(troveId);

        // 2. a permissionless shutdown() also gives up instead of escalating
        bo.shutdown();
        assertFalse(bo.hasBeenShutDown(), "no escalation to shutdown");
        assertEq(tm.shutdownTime(), 0, "shutdownTime still unset");

        // 3. because no shutdown state is reachable, the urgent path cannot be used either
        vm.prank(user);
        vm.expectRevert(TroveManager.NotShutDown.selector);
        tm.urgentRedemption(1e18, _ids(troveId), 0);

        // 4. a pure repayment does work, so the branch is paused rather than dead; still no coll out
        vm.prank(user);
        bo.repayJpydf(troveId, 1e18);
        assertEq(coll.balanceOf(user), 100_000e18, "no collateral returns while paused");

        // 5. and the close still reverts after a successful risk-decreasing operation
        vm.prank(user);
        vm.expectRevert(BorrowerOperations.NewOracleFailureDetected.selector);
        bo.closeTrove(troveId);
    }

    /// @dev once the quote is live again the same close goes through, so the freeze tracks the outage
    function testSameClosePassesWhenTheQuoteRecovers() public {
        uint256 troveId = _open(100_000e18);
        _open2();
        _fund();

        feed.setFailing(true);
        vm.prank(user);
        vm.expectRevert(BorrowerOperations.NewOracleFailureDetected.selector);
        bo.closeTrove(troveId);

        feed.setFailing(false);
        vm.prank(user);
        bo.closeTrove(troveId);
        assertGt(coll.balanceOf(user), 300_000e18, "collateral returned after recovery");
    }

    function testBatchLiquidateSucceedsSilentlyWhenOracleFails() public {
        uint256 troveId = _open(225_000e18);
        _open2();
        _fund();

        // price falls: ICR 300k/225k -> 113%, under the 120% MCR
        feed.setPrice(0.85e18);
        feed.setFailing(true);

        vm.recordLogs();
        tm.batchLiquidateTroves(_ids(troveId));

        // succeeds, but nothing happens and no Liquidation event is emitted
        assertEq(uint256(tm.getTroveStatus(troveId)), 1, "trove still active");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 liqs;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ITroveEvents.Liquidation.selector) liqs++;
        }
        assertEq(liqs, 0, "no Liquidation event");

        // same call, same price, once the feed answers again
        feed.setFailing(false);
        tm.batchLiquidateTroves(_ids(troveId));
        assertEq(uint256(tm.getTroveStatus(troveId)), 3, "closed by liquidation");
    }

    function _ids(uint256 _id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = _id;
    }
}

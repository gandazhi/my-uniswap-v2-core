pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    // 最小流通性 1000
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // 合约中把方法转成bytes再hash最 后取前4位就是合约方法的selecetor
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    // 工厂合约的地址
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves 最后更新时间戳

    /**
    在价格预言机中会使用到
    记录在上一次交易发生后，token0的累计价格变化（以token1点价格计价）
    主要用于计算交易时的价格更新；
    如果token0的累计价格变化大于0 则使用price0CumulativeLast作为新的价格
    如果token0的累计价格变化小于0 则使用price1CumulativeLast作为新的价格
     */
    // 价格0最后累计
    uint public price0CumulativeLast;
    // 价格1最后累计
    uint public price1CumulativeLast;
    // 最后一次流动性事件之后的K值 reserve0 * reseerve1 = kLast 在最近的流动性事件之后立即生效
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;
    // 可重入锁
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    // 获取剩余代币数量和最后更新时间戳
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        // 目标合约地址.call(abi.encodeWithSelector("函数选择器", 逗号分隔的具体参数)); 它的返回值为(bool, data)，分别对应call是否成功以及目标函数的返回值。
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // 确认返回值为true并且响应长度大于0或者解码为true
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    // 铸造事件
    event Mint(address indexed sender, uint amount0, uint amount1);
    // 销毁时间
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    // 交换事件
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    // 同步事件
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // factory合约创建的时候，调用一次
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // 更新储备量 并且每个区块链第一次调用的时候更新价格累加器
    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 确保token0余额和token1余额都大于0
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // 当前时间戳转换为uint32
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // 对比当前时间戳与上一次更新时间戳 计算时间流逝
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        // 前时间戳 - 上一次更新时间戳 > 0 并且 储备量0不等于0 并且 储备量1不等于0
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // 价格0最后累计 += 储备量1 * 2 * 112 / 储备量 0 * 时间流逝
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            // 价格1最后累计 += 储备量0 * 2 * 112 / 储备量 1 * 时间流逝
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 更新储备量0
        reserve0 = uint112(balance0);
        // 更新储备量1
        reserve1 = uint112(balance1);
        // 更新最后时间戳
        blockTimestampLast = blockTimestamp;
        // 出发同步时间
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 获取feeTo地址
        address feeTo = IUniswapV2Factory(factory).feeTo();
        // 如果工厂合约没有设置feeTo地址，则feeOn为false否则为true
        feeOn = feeTo != address(0);
        // 定义k值
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                // 计算（resever0×reserve1）的平方根
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                // 计算k值的平方根
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    /**
                    计算流动性公式:
                        liquidity = totalSupply * (rootK - rootKLast) / 5 * rootK + rootKLast
                     */
                    // 计算分子 UNI-V2总量 * (rootK - rootKLast)
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    // 计算分母 5 * rootK + rootKLast
                    uint denominator = rootK.mul(5).add(rootKLast);
                    // 计算流动性 分子 / 分母
                    uint liquidity = numerator / denominator;
                    // 如果流动性＞0 将流动性代币铸造给feeTo地址
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /**
    添加储备量的时候，铸造流动性代币给用户，流动性代币用于记录在流动性池中所拥有的数值
     */
    // 铸造 应该从执行重要安全检查的合约中调用此低级功能
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        // 获取储备量0、储备量1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 该配对合约地址中token0的代币数
        uint balance0 = IERC20(token0).balanceOf(address(this));
        // 该配对合约地址中token1的代币数
        uint balance1 = IERC20(token1).balanceOf(address(this));
        // amount0 = 余额0 - 储备量0
        uint amount0 = balance0.sub(_reserve0);
        // amount1 = 余额1 - 储备量1
        uint amount1 = balance1.sub(_reserve1);
        // 返回铸造费开关 如果工厂合约没有设置feeTo地址，则feeOn为false否则为true
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取totalSupply 这里必须定义 因为在并发情况下totalSupply可能会在_mintFee中更新 
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            // 流动性 = (amount0 * amount1)的平方根 - 最小流动性1000
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 在总量为0的初始情况下，永久锁定最低流动性
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // 流动性 = (amount0 * _totalSupply / _reserve0) (amount1 * _totalSupply / _reserve1) 取最小值
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        // 确保流动性大于0 
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 铸造流动性给to地址
        _mint(to, liquidity);
        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果铸造费开关开了 kLast = 储备量0 * 储备量1 更新最后流动性K值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发铸造事件
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
    路由合约调用
    销毁用户指定的流动性数值，根据流动性数值，按照比例计算出可以提取的token值，提取
     */
    // 销毁方法 应该从执行重要安全检查的合约中调用此低级功能
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        // 获取token0和token1点储备量
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // token0 合约地址
        address _token0 = token0;                                // gas savings
        // token1 合约地址
        address _token1 = token1;                                // gas savings
        // 获取当前合约在token0合约中的余额
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        // 获取当前合约在token1合约中的余额
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        // 获取当前合约的流动性 在路由合约中会先把用户移除的流动性转到配对合约中 
        uint liquidity = balanceOf[address(this)];

        // 获取铸造费开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取流动性总量 必须在这里用临时变量获取，因为可能会在_mintFee方法中更新
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 计算token0的数量 销毁的流动性值 * token0剩余的数量 / 流动性池总量 使用余额确保按比例分配
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        // 计算token1的数量 销毁的流动性值 * token1剩余的数据 / 流动性池总量 使用余额确保按比例分配
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        // 确保提取的token0和token1的数据大于0
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        // 销毁流动性
        _burn(address(this), liquidity);
        // 向用户to地址转token0
        _safeTransfer(_token0, to, amount0);
        // 向用户to地址转token1
        _safeTransfer(_token1, to, amount1);
        // 更新配对合约中的 token0余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        // 更新配对合约中的 token1余额
        balance1 = IERC20(_token1).balanceOf(address(this));

        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果铸造费开发打开 重新计算kLast值
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发销毁事件
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}

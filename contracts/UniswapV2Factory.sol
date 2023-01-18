pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    // 收取交易手续费地址
    address public feeTo;
    // 设置交易手续费控制权限地址
    address public feeToSetter;
    // 获取配对合约地址  token0 => (token1 => pair)
    mapping(address => mapping(address => address)) public getPair;
    // 所有配对合约地址数组
    address[] public allPairs;
    /**
        事件 创建配对合约
        token0: token0地址 index将参数作为topic处理 可以作为条件筛选过滤
        token1: token1地址 index将参数作为topic处理 可以作为条件筛选过滤
        pair: 配对合约地址
        uint: allPairs数组长度--可以当作序号
     */ 
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // 验证tokenA不能等于tokenB
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // 排序
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // 验证token地址 token0 != address(0); token0 != token1; 所以 token1 != address(0)
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 验证配对合约地址是否存在
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        // 获得UniswapV2Pair合约编译后的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // 将tokeno和token1地址打包 hash
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // 内联汇编
        assembly {
            /**
                create2详情:https://wtf.academy/solidity-advanced/Create2/
                create2 计算一个地址，并且将新合约部署到该地址上去
                uniswap v2 用solidity 0.5写的，不能直接使用create2 opcode 使用汇编
                在当前0.8版本中 与以下代码相同
                pair := new UniswapV2Pair{salt: salt}()
             */
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // 初始化配对合约
        IUniswapV2Pair(pair).initialize(token0, token1);
        // 有两个状态变量getPair是两个代币地址到币对地址的map，方便根据代币找到币对地址
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // allPairs是币对地址的数组，存储了所有币对地址。
        allPairs.push(pair);
        // 调用配对合约创建事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    // 设置手续费收取账号地址
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    // 转让合约管理员
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}

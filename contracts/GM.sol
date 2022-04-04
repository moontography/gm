// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.4;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';

contract GM is ERC20, Ownable {
  uint256 private constant PERCENT_DENOMENATOR = 1000;

  address payable public treasury;

  mapping(address => bool) private _isTaxExcluded;
  bool private _taxesOff;
  uint256 private _taxTreasury = 40; // 4%

  uint256 private _liquifyRate = 10; // 1% of LP balance
  uint256 public launchTime;

  IUniswapV2Router02 public uniswapV2Router;
  address public uniswapV2Pair;

  mapping(address => bool) private _isBot;
  address[] private _confirmedBots;

  bool private _swapEnabled = true;
  bool private _swapping = false;
  modifier lockSwap() {
    _swapping = true;
    _;
    _swapping = false;
  }

  constructor() ERC20('gm', 'GM') {
    _mint(address(this), 1_000_000_000_000 * 10**18);

    IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
      0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
    );
    uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(
      address(this),
      _uniswapV2Router.WETH()
    );
    uniswapV2Router = _uniswapV2Router;

    _isTaxExcluded[address(this)] = true;
    _isTaxExcluded[msg.sender] = true;
  }

  // _supplyPercentLp: 1 = 0.1%, 1000 = 100%
  function launch(uint16 _supplyPercentLp) external payable onlyOwner {
    require(launchTime == 0, 'already launched');
    require(msg.value > 0, 'need ETH for initial LP');
    require(
      _supplyPercentLp <= PERCENT_DENOMENATOR,
      'cannot add more than supply to LP'
    );

    uint256 _supplyForLp = (totalSupply() * _supplyPercentLp) /
      PERCENT_DENOMENATOR;
    uint256 _leftover = totalSupply() - _supplyForLp;
    if (_supplyForLp > 0) {
      _addLp(_supplyForLp, msg.value);
    }
    if (_leftover > 0) {
      _transfer(address(this), owner(), _leftover);
    }
    launchTime = block.timestamp;
  }

  function _transfer(
    address sender,
    address recipient,
    uint256 amount
  ) internal virtual override {
    bool _isOwner = sender == owner() ||
      recipient == owner() ||
      msg.sender == owner();
    require(!_isBot[recipient], 'Stop botting!');
    require(!_isBot[sender], 'Stop botting!');
    require(!_isBot[_msgSender()], 'Stop botting!');
    uint256 contractTokenBalance = balanceOf(address(this));

    bool _isBuy = sender == uniswapV2Pair &&
      recipient != address(uniswapV2Router);
    bool _isSell = recipient == uniswapV2Pair;
    bool _isSwap = _isBuy || _isSell;
    if (_isSwap) {
      if (block.timestamp == launchTime) {
        _isBot[recipient] = true;
        _confirmedBots.push(recipient);
      }
    }

    uint256 _minSwap = (balanceOf(uniswapV2Pair) * _liquifyRate) /
      PERCENT_DENOMENATOR;
    bool _overMin = contractTokenBalance >= _minSwap;
    if (
      _swapEnabled &&
      !_swapping &&
      !_isOwner &&
      _overMin &&
      launchTime != 0 &&
      sender != uniswapV2Pair
    ) {
      _swap(_minSwap);
    }

    uint256 tax = 0;
    if (
      launchTime != 0 &&
      _isSwap &&
      !_taxesOff &&
      !(_isTaxExcluded[sender] || _isTaxExcluded[recipient])
    ) {
      tax = (amount * _taxTreasury) / PERCENT_DENOMENATOR;
      if (tax > 0) {
        super._transfer(sender, address(this), tax);
      }
    }

    super._transfer(sender, recipient, amount - tax);
  }

  function _swap(uint256 contractTokenBalance) private lockSwap {
    uint256 balBefore = address(this).balance;

    // generate the uniswap pair path of token -> weth
    address[] memory path = new address[](2);
    path[0] = address(this);
    path[1] = uniswapV2Router.WETH();

    _approve(address(this), address(uniswapV2Router), contractTokenBalance);
    uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
      contractTokenBalance,
      0,
      path,
      address(this),
      block.timestamp
    );

    uint256 balToProcess = address(this).balance - balBefore;
    if (balToProcess > 0) {
      _processFees(balToProcess);
    }
  }

  function _addLp(uint256 tokenAmount, uint256 ethAmount) private {
    _approve(address(this), address(uniswapV2Router), tokenAmount);
    uniswapV2Router.addLiquidityETH{ value: ethAmount }(
      address(this),
      tokenAmount,
      0,
      0,
      treasury == address(0) ? owner() : treasury,
      block.timestamp
    );
  }

  function _processFees(uint256 amountETH) private {
    address payable _treasury = treasury == address(0)
      ? payable(owner())
      : treasury;
    _treasury.call{ value: amountETH }('');
  }

  function isRemovedBot(address account) external view returns (bool) {
    return _isBot[account];
  }

  function removeBot(address account) external onlyOwner {
    require(
      account != address(uniswapV2Router),
      'cannot not blacklist Uniswap'
    );
    require(!_isBot[account], 'user is already blacklisted');
    _isBot[account] = true;
    _confirmedBots.push(account);
  }

  function amnestyBot(address account) external onlyOwner {
    require(_isBot[account], 'user is not blacklisted');
    for (uint256 i = 0; i < _confirmedBots.length; i++) {
      if (_confirmedBots[i] == account) {
        _confirmedBots[i] = _confirmedBots[_confirmedBots.length - 1];
        _isBot[account] = false;
        _confirmedBots.pop();
        break;
      }
    }
  }

  function setTaxTreasury(uint256 _tax) external onlyOwner {
    require(
      _tax <= (PERCENT_DENOMENATOR * 20) / 100,
      'tax cannot be above 20%'
    );
    _taxTreasury = _tax;
  }

  function setTreasury(address _treasury) external onlyOwner {
    treasury = payable(_treasury);
  }

  function setLiquifyRate(uint256 _rate) external onlyOwner {
    require(_rate <= PERCENT_DENOMENATOR / 10, 'cannot be more than 10%');
    _liquifyRate = _rate;
  }

  function setIsTaxExcluded(address _wallet, bool _isExcluded)
    external
    onlyOwner
  {
    _isTaxExcluded[_wallet] = _isExcluded;
  }

  function setTaxesOff(bool _areOff) external onlyOwner {
    _taxesOff = _areOff;
  }

  function setSwapEnabled(bool _enabled) external onlyOwner {
    _swapEnabled = _enabled;
  }

  function withdrawETH() external onlyOwner {
    payable(owner()).call{ value: address(this).balance }('');
  }

  receive() external payable {}
}

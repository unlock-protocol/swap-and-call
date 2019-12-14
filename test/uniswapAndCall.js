const BigNumber = require("bignumber.js");
const { protocols, tokens } = require("hardlydifficult-ethereum-contracts");
const UniswapAndCall = artifacts.require("UniswapAndCall.sol");
const truffleAssert = require("truffle-assertions");

async function createExchange(uniswap, token, tokenOwner) {
  let tx = await uniswap.createExchange(token.address, {
    from: tokenOwner
  });
  const exchange = await protocols.uniswap.getExchange(
    web3,
    tx.logs[0].args.exchange
  );
  await token.mint(tokenOwner, "1000000000000000000000000", {
    from: tokenOwner
  });
  await token.approve(exchange.address, -1, { from: tokenOwner });
  await exchange.addLiquidity(
    "1",
    "1000000000000000000000000",
    Math.round(Date.now() / 1000) + 60,
    {
      from: tokenOwner,
      value: web3.utils.toWei("1", "ether")
    }
  );

  return exchange;
}

contract("uniswapAndCall", accounts => {
  const owner = accounts[0];
  const testAccount = accounts[2];
  const keyPrice = web3.utils.toWei("0.00042", "ether");
  let targetToken;
  let sourceToken;
  let targetExchange;
  let sourceExchange;
  let lock;
  let uniswapAndCall;
  let callData;

  beforeEach(async () => {
    // Token
    targetToken = await tokens.sai.deploy(web3, owner);
    sourceToken = await tokens.sai.deploy(web3, owner);

    // Uniswap exchange with liquidity for testing
    const uniswap = await protocols.uniswap.deploy(web3, owner);
    targetExchange = await createExchange(uniswap, targetToken, owner);
    sourceExchange = await createExchange(uniswap, sourceToken, owner);

    // Lock priced in ERC-20 tokens
    lock = await protocols.unlock.createTestLock(
      web3,
      accounts[9], // Unlock Protocol owner
      accounts[1], // Lock owner
      {
        tokenAddress: targetToken.address,
        keyPrice
      }
    );
    callData = web3.eth.abi.encodeFunctionCall(
      lock.abi.find(e => e.name === "purchaseFor"),
      [testAccount]
    );

    // UniswapAndCall
    uniswapAndCall = await UniswapAndCall.new(uniswap.address);
  });

  it("Sanity check: Can't purchase keys with ether", async () => {
    await truffleAssert.fails(
      lock.purchaseFor(testAccount, {
        from: testAccount,
        value: await targetExchange.getEthToTokenOutputPrice(keyPrice)
      })
    );
  });

  describe("Purchase with tokens", () => {
    beforeEach(async () => {
      await targetToken.mint(testAccount, "1000000000000000000000000", {
        from: owner
      });
      await targetToken.approve(lock.address, -1, { from: testAccount });
    });

    it("Sanity check: Can purchase keys with tokens", async () => {
      await lock.purchaseFor(testAccount, {
        from: testAccount
      });
    });
  });

  it("Can purchase keys with ether via UniswapAndCall", async () => {
    await uniswapAndCall.uniswapEthAndCall(
      targetToken.address,
      keyPrice,
      lock.address,
      callData,
      {
        from: testAccount,
        value: new BigNumber(
          await targetExchange.getEthToTokenOutputPrice(keyPrice)
        )
          .times(1.1)
          .dp(0, BigNumber.ROUND_UP)
      }
    );

    const hasKey = await lock.getHasValidKey(testAccount);
    assert.equal(hasKey, true);
  });

  describe("started with sourceTokens", () => {
    beforeEach(async () => {
      await sourceToken.mint(testAccount, "1000000000000000000000000", {
        from: owner
      });
      await sourceToken.approve(uniswapAndCall.address, -1, {
        from: testAccount
      });
    });

    it("Can purchase keys with sourceTokens via UniswapAndCall", async () => {
      await uniswapAndCall.uniswapTokenAndCall(
        sourceToken.address,
        await sourceToken.balanceOf(testAccount),
        targetToken.address,
        keyPrice,
        lock.address,
        callData,
        {
          from: testAccount
        }
      );

      const hasKey = await lock.getHasValidKey(testAccount);
      assert.equal(hasKey, true);
    });
  });
});

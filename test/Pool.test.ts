import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import hre, { ethers } from 'hardhat'
import { ERC20, GenericERC20, Pool } from '../types'
import {
  changeBalance,
  serializeOther,
  setChainState,
  unlockAddresses,
} from './tools'
import { Contract, BigNumber } from 'ethers'
import { expect } from 'chai'
require('dotenv').config()
import { time } from '@nomicfoundation/hardhat-network-helpers'

const TOTAL_SUPPLY = BigNumber.from(10).pow(18).mul(1000000)

describe('E2E Test', function () {
  // Contract instances
  let Pool: Pool
  let USDC: GenericERC20
  let CBETH: GenericERC20

  // Users
  let cbETHWhale: SignerWithAddress
  let usdcWhale: SignerWithAddress

  // Set a long timeout since networking forking can be slow
  this.timeout(500000)

  beforeEach(async function () {
    ;[cbETHWhale, usdcWhale] = await ethers.getSigners()

    // Deploy contracts
    USDC = (await (await ethers.getContractFactory('GenericERC20')).deploy(
      BigNumber.from(10).pow(6).mul(1000000),
      'USD Coin',
      'USDC',
      6,
    )) as GenericERC20
    CBETH = (await (await ethers.getContractFactory('GenericERC20')).deploy(
      BigNumber.from(10).pow(6).mul(1000000),
      'USD Coin',
      'USDC',
      6,
    )) as GenericERC20

    Pool = (await (await ethers.getContractFactory('Pool')).deploy()) as Pool

    await USDC.mint100(usdcWhale.address)
    await CBETH.mint100(cbETHWhale.address)
  })

  context('E2E test', function () {
    const LOAN_DURATION = 1000

    it('Create and Cancel Loan', async function () {
      await CBETH.approve(Pool.address, 100)
      await Pool.create(
        CBETH.address,
        100,
        USDC.address,
        100,
        BigNumber.from((await time.latest()) + LOAN_DURATION),
      )

      await Pool.cancel(
        CBETH.address,
        100,
        USDC.address,
        100,
        BigNumber.from((await time.latest()) + LOAN_DURATION),
      )
    })

    it('Create, Fill Loan, and Repay Before Expiration', async function () {
      const expirationTime = BigNumber.from(
        (await time.latest()) + LOAN_DURATION,
      )
      await CBETH.approve(Pool.address, 100)
      await Pool.connect(cbETHWhale).create(
        CBETH.address,
        100,
        USDC.address,
        100,
        expirationTime,
      )

      await USDC.connect(usdcWhale).approve(Pool.address, 100)
      await Pool.connect(usdcWhale).fill(
        cbETHWhale.address,
        CBETH.address,
        100,
        USDC.address,
        100,
        expirationTime,
      )

      await USDC.connect(cbETHWhale).approve(Pool.address, 100)
      await Pool.connect(cbETHWhale).repay(
        cbETHWhale.address,
        CBETH.address,
        100,
        USDC.address,
        100,
        expirationTime,
      )
    })

    it('Create, Fill Loan, and Repay After Expiration', async function () {
      const expirationTime = BigNumber.from(
        (await time.latest()) + LOAN_DURATION,
      )
      await CBETH.approve(Pool.address, 100)
      await Pool.connect(cbETHWhale).create(
        CBETH.address,
        100,
        USDC.address,
        100,
        expirationTime,
      )

      await USDC.connect(usdcWhale).approve(Pool.address, 100)
      await Pool.connect(usdcWhale).fill(
        cbETHWhale.address,
        CBETH.address,
        100,
        USDC.address,
        100,
        expirationTime,
      )

      await USDC.connect(cbETHWhale).approve(Pool.address, 100)
      await Pool.connect(cbETHWhale).claim(
        cbETHWhale.address,
        CBETH.address,
        100,
        USDC.address,
        100,
        expirationTime,
      )
    })
  })
})

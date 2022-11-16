import {promises as fs} from "fs";
import {BigNumber, BigNumberish, Contract, providers} from "ethers";
import hre, {ethers} from "hardhat";
import {HardhatRuntimeEnvironment} from "hardhat/types";
import {getStorageAt, impersonateAccount, mine, setStorageAt, setBalance, time} from "@nomicfoundation/hardhat-network-helpers";

const encode = (types: any, values: any) => ethers.utils.defaultAbiCoder.encode(types, values);

export const changeBalance = async (
    hre: HardhatRuntimeEnvironment,
    tokenAddress: string,
    holderAddress: string,
    newValue: BigNumber,
    solidity = true,
    verbose = false,
    offset?: number,
) => {
    const {ethers} = hre;
    // Pad the address into 32 byte word
    const paddedAddress = ethers.utils.hexZeroPad(ethers.utils.getAddress(holderAddress), 32);
    if (!offset) {
        offset = await findBalancesSlot(hre, tokenAddress, solidity);
        if (verbose) console.info("Slot", offset);
    }
    // Calculate the memory location in the mapping(address => uint256)
    let memoryLocation: string;
    if (solidity) {
        memoryLocation = ethers.utils.solidityKeccak256(["address", "uint256"], [paddedAddress, offset]);
    } else {
        memoryLocation = ethers.utils.solidityKeccak256(["uint256", "address"], [offset, paddedAddress]);
    }
    if (verbose) {
        console.info("Token Addr", tokenAddress);
        console.info("Previous value", await ethers.provider.getStorageAt(tokenAddress, memoryLocation));
    }

    // Remove any "0x0" or "0x00" which caused issues
    memoryLocation = memoryLocation.replace("0x00", "0x");
    memoryLocation = memoryLocation.replace("0x0", "0x");

    // Pad the new value into a 32 byte word
    const paddedNewValue = ethers.utils.hexZeroPad(newValue.toHexString(), 32);
    await setStorageAt(tokenAddress, memoryLocation, paddedNewValue);
    const token = await ethers.getContractAt("ERC20", tokenAddress);
    const actualNewBalance = await token.balanceOf(holderAddress);
    if (verbose) {
        console.log("New value", await token.balanceOf(holderAddress));
    }
    if (actualNewBalance.lt(newValue)) {
        throw new Error(`New balance less than intended: ${actualNewBalance} < ${newValue}`);
    }
};


/**
 * @param {HardHatRuntimeEnviroment} hre the Hardhat runtime environment
 * @param {number} block the block at which we want to replicate
 **/

export const setChainState = async (hre: HardhatRuntimeEnvironment, block?: number, jsonRpcUrl: string = `https://rpc.dev.riskharbor.com/mainnet`) => {
    if (!block) {
        return await hre.network.provider.request({
            method: "hardhat_reset",
            params: [
                {
                    forking: {
                        jsonRpcUrl,
                        blockNumber: await getMostRecentForkableBlock(jsonRpcUrl),
                        ignoreUnknownTxType: true,
                    },
                },
            ],
        });
    } else if (block === 0) {
        return await hre.network.provider.request({
            method: "hardhat_reset",
            params: [
                {
                    forking: {
                        jsonRpcUrl,
                        ignoreUnknownTxType: true,
                    },
                },
            ],
        });
    } else {
        return await hre.network.provider.request({
            method: "hardhat_reset",
            params: [
                {
                    forking: {
                        jsonRpcUrl,
                        blockNumber: block,
                        ignoreUnknownTxType: true,
                    },
                },
            ],
        });
    }
};

export const findBalancesSlot = async (hre: HardhatRuntimeEnvironment, tokenAddress: string, solidity: boolean) => {
    const account = ethers.constants.AddressZero;
    const probeA = encode(["uint"], [1]);
    const probeB = encode(["uint"], [2]);
    const token = await ethers.getContractAt("ERC20", tokenAddress);
    for (let i = 0; i < 750; i++) {
        let probedSlot: string;
        if (solidity) {
            probedSlot = ethers.utils.keccak256(encode(["address", "uint"], [account, i]));
        } else {
            probedSlot = ethers.utils.keccak256(encode(["uint", "address"], [i, account]));
        }

        // remove padding for JSON RPC
        while (probedSlot.startsWith("0x0")) probedSlot = "0x" + probedSlot.slice(3);
        const prev = await getStorageAt(tokenAddress, ethers.utils.hexZeroPad(probedSlot, 32), "latest");
        // make sure the probe will change the slot value
        const probe = prev === probeA ? probeB : probeA;
        await setStorageAt(tokenAddress, probedSlot, probe);

        const balance = await token.balanceOf(account);
        // reset to previous value
        await setStorageAt(tokenAddress, probedSlot, prev);
        if (balance.eq(ethers.BigNumber.from(probe))) return i;
    }
    throw new Error("Balances slot not found!");
};
/** BigNumber to hex string of specified length */
export function toFixedHex(number: BigNumberish, length = 32): string {
    let result = "0x" + (number instanceof Buffer ? number.toString("hex") : BigNumber.from(number).toHexString().replace("0x", "")).padStart(length * 2, "0");

    if (result.indexOf("-") > -1) {
        result = "-" + result.replace("-", "");
    }

    return result;
}
export const getMostRecentForkableBlock = async (jsonRpcUrl: string = `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALCHEMY_API_KEY}`) => {
    const rpcProvider = new ethers.providers.JsonRpcProvider(jsonRpcUrl);
    if (jsonRpcUrl.includes("eth")) {
        return (await rpcProvider.getBlockNumber()) - 10;
    } else if (jsonRpcUrl.includes("arbitrum")) {
        const rpcProvider = new ethers.providers.InfuraProvider(jsonRpcUrl);
        return (await rpcProvider.getBlockNumber()) - 30;
    }
};

/**
 * Increases the block time by the given amount of time(seconds)
 * @param {HardhatRuntimeEnvironment} hre the Hardhat runtime environment
 * @param {number} amountInSeconds the time to increase
 */
export const increaseTime = async (hre: HardhatRuntimeEnvironment, amountInSeconds: number) => {
    await time.increase(amountInSeconds);
    await mine();
};

/**
 * Convert an array of hex strings into a single hex string. This is useful when
 * packing the other struct with bytes.
 * @param otherArr Array of hex strings, each string should start with 0x....
 * @returns
 */
export const serializeOther = async (otherArr: string[]) => {
    let otherString: string = "";
    if (otherArr.length === 0) {
        return otherString;
    }
    otherString += otherArr[0];
    for (let i = 1; i < otherArr.length; i++) {
        otherString += otherArr[i].substring(2);
    }
    return otherString;
};

export const unlockAddresses = async (hre: HardhatRuntimeEnvironment, addresses: string[], fillEth = false): Promise<providers.JsonRpcSigner[]> => {
    const {ethers} = hre;
    const signerArr: providers.JsonRpcSigner[] = new Array(addresses.length);

    let i = 0;
    for await (const address of addresses) {
        await impersonateAccount(address);
        if (fillEth) {
            await setBalance(address, "0x56BC75E2D63100000");
        }
        signerArr[i] = ethers.provider.getSigner(address);
        i++;
    }
    return signerArr;
};

export const exploreContractMemory = async (address: string, runs: number, startingIndex = 0) => {
    for (let i = startingIndex; i < runs; i++) {
        let res = await ethers.provider.getStorageAt(address, i);
        res = ethers.utils.hexStripZeros(res);
        if (!ethers.utils.isAddress(res)) {
            res = String(parseInt(res, 16));
        }
        console.log(i, res);
    }
};

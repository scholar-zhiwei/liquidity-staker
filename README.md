# @uniswap/liquidity-staker

Forked from 
[https://github.com/Synthetixio/synthetix/tree/v2.27.2/](https://github.com/Synthetixio/synthetix/tree/v2.27.2/)

用户挖矿奖励的计算：用户stake时 存储当时每token奖励的数额 , 到用户withdraw时，此时的每token奖励的数额 - stake时存储当时每token奖励的数额  == token奖励数额的增量 * 质押token数量 + 未领取的挖矿奖励数额  == 最终总挖矿奖励数量
 


本合约质押的时间是有限制，然后在通过总的奖励数额reward因此才可以获取每秒的奖励数额是多少rewardRate



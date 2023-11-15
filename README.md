# Possum Portals
Enabling Users To Claim Fee-Less Upfront Yield

Portals is upping the game by creating permissionless and immutable contracts that allow users to deposit yield-bearing assets and receive their yield up-front. In other words, depositors can get months worth of yield immediately after they deposit! 
On top of that, the depositor retains the flexibility to withdraw deposits at any time by paying back part of the upfront yield

There are **four actors** in the Portals system: *depositors, speculators, funders* and *arbitrageurs*

## Depositors
The primary user of Portals is the depositor who’s looking to take advantage of upfront yield opportunities, such as locking in a high yield rate or getting access to leverage without risk of liquidation 
* stake the accepted principal token
* generate Portal Energy, a system internal unit of account
* convert Portal Energy into PSM
* receive upfront yield in PSM

One way to think of this process is as if the depositor is depositing “cumulative time.”
For example, if you deposit 1000 USDC for 6 months, you’d have 6,000 “cumulative months” that you have to wait before you withdraw your last USDC. But in the meantime, you can withdraw a portion of your assets at any point. Say you withdraw $500 worth of PSM tokens immediately – the total still needs to equal 6,000 months, so each of the 500 remaining USDC in the Portal needs to be there for 12 months (12 * 500 = 6000).
So, on a high-level basis, the depositor deposits USDC and receives PSM from a Portal. 

But how did that PSM get in the Portal in the first place? Through one of two sources: 
* Initial funders who provide funding to the Portals before they launch
* Arbitrageurs who see a mismatch between PSM’s market value and its value within the Portal 

## Speculators
The second user of Portals is the yield speculator. If the provided yield in a portal is lower than what can be expected in the future, a yield speculator can buy future yield to sell it at a higher price later.
* Buy Portal Energy with PSM directly in the Portal
* Sell Portal Energy back to PSM to close the trade

## Funders
When a specific Portal is ready to launch, it’ll undergo an initial funding phase where funders can deposit PSM tokens. 
In return, they’re given receipt tokens based on the “rewardRate.” For example, if someone deposits 100 PSM tokens and the rewardRate is 1,000%, they’ll get receipt tokens for 1000 PSM.
These receipt tokens, called bTokens, can later be redeemed for PSM. 
* contribute PSM during funding phase
* receive bTokens
* redeem (burn) bTokens against a pro-rata share of the reward pool in PSM

## Arbitrageurs
Anyone can sweep the Portal's balance of any token by paying a fixed amount of PSM to the Portal. (PSM and the principal token are excluded)
This is an effective means to convert accruing yield to PSM which refills the internal LP and by extension refills available upfront yield.
If the value of the sweeped token balance is larger than the value of the fixed amount of PSM, an arbitrage profit is compelling independent actors to call the convert() function. A part of the PSM proceeds is allocated to the reward pool to pay back funders.
* Sweep the Portal's balance of a specific token via convert()
* Pay a fixed amount of PSM
* Refill the internal LP
* increase the reward pool for funders


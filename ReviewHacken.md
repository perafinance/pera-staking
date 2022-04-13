## High

1. Unrelibale behaviour risks minimized. Users staked tokens will not be reachable.
2. The token list is controlled by owner and there are not any external calls inside the loop. The list size will not be growed much by the owner. Also, the list can be reduced. So, DOS risks are prevented
3. Token balance controls are not included since there are multiple token distributing scenarios, but they will be controlled by our backend and required tokens will be provided for the contract. Also, single token claiming is avaliable and it's preferred option.
4. TotalRewardBalance only keeps unallocated tokens for the days. It's not a real balance for tokens, so shouldn't be decreased after the claim.
5. A control statement to block claims of staked tokens is included.

## Medium

1. It's unnecessary to check in contract and revert before the claim since it will be checked by safeTransfer functions.
2. Our contracts user base are not contract accounts and call function may bring more risks. So transfer method is preffered.
3. Transfer method doesn't have a return value to be checked.
4. Return value checks included.

## Low

1. Zero address validations are done.
2. Unused variable removed.
3. The function uses these hardcoded values for optimization and we accept them to make safer math operations.
4. It should be public. Its mock alternative is removed misunderstanding fixed.
5. Compile and deploy operations will be checked
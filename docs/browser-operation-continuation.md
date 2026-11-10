# Browser operation continuation

The indexed page operator owns one bounded execution of a user goal. It observes
before each action and permits up to 32 steps. Cancellation stops subsequent
inspection and mutations. Loop detection compares both the complete observed
snapshot and the interpreted decision. Three identical decisions on an unchanged
snapshot stop the loop. Consecutive clicks on different targets are valid.

Acceptance includes more than eight steps, different consecutive click targets,
changed page state for the same target, identical no-progress decisions, and
cancellation before executing a decision.

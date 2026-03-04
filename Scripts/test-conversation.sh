#!/bin/bash
# Simulates a two-person meeting conversation via system audio.
# Start a recording in Grey Eminence FIRST, then run this script.
# System audio capture will pick up the voices.
# Speak into your mic between lines to test the mic channel too.

echo "Starting test conversation in 3 seconds..."
echo "Make sure Grey Eminence is recording!"
sleep 3

say -v Samantha "Good morning everyone, let's get started with our weekly standup." &
wait
sleep 1

say -v Daniel "Morning. I finished the API integration yesterday and pushed it to the staging branch." &
wait
sleep 1

say -v Samantha "Great work. Did you run into any issues with the authentication flow?" &
wait
sleep 1

say -v Daniel "Actually yes, the token refresh was failing intermittently. I added a retry mechanism with exponential backoff, and that seems to have fixed it." &
wait
sleep 1

say -v Samantha "Good catch. Can you document that in the technical notes? I want to make sure the team knows about that pattern." &
wait
sleep 1

say -v Daniel "Sure, I'll write that up today. I also need to review the pull request from the frontend team." &
wait
sleep 1

say -v Samantha "That reminds me, we need to schedule a design review for the new dashboard. Can you set that up for Thursday?" &
wait
sleep 1

say -v Daniel "Will do. Thursday afternoon works best for everyone I think. I'll send out the invite after this meeting." &
wait
sleep 1

say -v Samantha "Perfect. One more thing, the client demo is next Tuesday. We should do a dry run on Monday. Can you prepare the test data?" &
wait
sleep 1

say -v Daniel "Absolutely. I'll have the test dataset ready by Friday so we have the weekend buffer just in case." &
wait
sleep 1

say -v Samantha "Excellent. I think that covers everything. Thanks everyone, talk to you tomorrow." &
wait

echo ""
echo "Test conversation complete."

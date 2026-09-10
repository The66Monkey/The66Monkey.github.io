# AI‑Assisted Coding: Why “Vibes” Don’t Ship Software

There ain’t no fucking vibe in professional software development.
You either build something that works, or you don’t.

Every developer starts the same way: copying code, ripping apart examples, stitching features together, and learning by breaking things. It’s the same as any craft — you take the machine apart, you put it back together, and you figure out why it rattles.

Stack Overflow became a meme because every coder has, at some point, crawled in there at 3 AM, desperate for a fix that wasn’t buried under ten layers of contradictory answers.

## GitHub Copilot: The Agent That Launched a Thousand Script Kiddies

I’ve already written about what the world looked like when I started, but I didn’t get to rant about the real problem with AI-assisted coding: you still have to do a ridiculous amount of tweaking, testing, and restating your goals.

LLMs get you to the testing phase faster, sure. It feels like progress. But when you’re working on anything modern — bleeding-edge frameworks, new APIs, fresh documentation — you end up iterating more than ever.

For me, getting the latest suite of pentest tools working has been something like:

    40% LLM prompting

    50% reading documentation

    10% swearing at dependency conflicts

And here’s the uncomfortable truth:
If you want a website from six years ago, a script for a stable legacy system, or a mockup that looks vaguely correct, an LLM is a cheat sheet. It throws out working-but-not-optimal code that gets you moving in the general direction.

But if you want to ship something?

You almost always have to rebuild the entire thing from scratch because the model made some assumption early on that quietly poisoned the architecture.

# The Real Problems

    Legacy bias — Most training data is pre‑2023. Even with RAG, the ratio of outdated solutions to correct modern ones is absurd.

    Goal drift — If you don’t restate your intent constantly, the model wanders off into whatever pattern its training data thinks is “normal.”

    Hidden assumptions — The model picks a framework, a pattern, or a dependency without telling you. You only discover it when everything breaks later.

    Iteration inflation — You get to the testing phase faster, but you test more because the initial scaffolding is shaky.

# Why Pros Still Need Documentation

Documentation is still the only source of truth.
Not vibes.
Not autocomplete.
Not “here’s a snippet from a 2018 blog post.”

If you’re building something modern — new kernel features, new Android ROM quirks, new cloud APIs, new pentest tooling — the LLM is only as good as the documentation you feed it and the constraints you enforce.

AI is a tool, and one that is getting more diluted and rickety each year.
The next generation of code assistant's will need to be much better at reading and using documentation if they are to remain a usable tool, and developers are going to need to continue producing high quality documentation.

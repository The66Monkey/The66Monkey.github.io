AI‑Assisted Coding: Why “Vibes” Don’t Ship Software

There ain’t no fucking vibe in professional software development.
You build something that works, or you don’t.

Every developer starts the same way: copying code, tearing apart examples, stitching features together, and learning by breaking things. It’s the same as any craft — you take the machine apart, you put it back together, and you figure out why it rattles.

Stack Overflow became a rite of passage because every coder has, at some point, crawled in there at 3 AM, hunting for a fix buried under ten layers of contradictory answers.
GitHub Copilot: The Agent That Launched a Thousand Script Kiddies

There’s a strange parallel between the rise of Copilot and the old wave of script kiddies.
Both groups gained access to powerful tools long before they gained the understanding required to wield them.

A script kiddie fires off payloads because the interface makes it feel like hacking.
An AI-assisted coder generates functions because the interface makes it feel like programming.
In both cases, the sense of capability comes from the tool’s output rather than the user’s internal model of how the system behaves.

This is why AI-assisted coding creates so much rework.
The model pushes you forward quickly, but it pushes you forward on rails it chose long before you noticed. When you’re building anything modern — new kernels, fresh APIs, evolving frameworks — those rails rarely match the direction your architecture needs to go. You get speed, but you also inherit every assumption baked into the generated scaffolding.

For me, getting the latest suite of pentest tools working has been a mix of LLM prompting, documentation reading, and the usual dependency chaos. The LLM helps me explore ideas faster, but the real progress comes from understanding why a particular approach fits the environment I’m targeting. That understanding doesn’t come from the model; it comes from reading, testing, and adjusting until the system behaves the way I expect.

If you’re building something old and stable, an LLM can act like a cheat sheet. It throws out workable code that gets you moving. But when you’re shipping something that needs to evolve, the early assumptions matter. The model often picks a framework, a pattern, or a dependency because its training data leans that way, and those choices shape everything that comes after. You end up rebuilding because the foundation wasn’t designed for the direction you needed to grow.
The Real Problems

Legacy bias shows up because most training data is pre‑2023, so the model leans toward patterns that were common years ago.
Goal drift happens because the model follows statistical momentum instead of architectural intent.
Hidden assumptions creep in when the model selects tools or structures without surfacing the reasoning.
Iteration inflation emerges because the generated scaffolding accelerates testing but increases the number of corrections required to reach a stable design.

Each of these issues comes from the same root: the model produces code based on patterns, while professionals build systems based on understanding.
Why Pros Still Need Documentation

Documentation remains the only reliable source of truth.
Modern systems evolve too quickly for statistical patterns to keep up, and the only way to align your architecture with reality is to read the material written by the people who actually maintain the thing you’re building on.

When you’re working with new kernel features, fresh Android ROM quirks, cloud APIs that change every quarter, or pentest tooling that depends on exact versions, the LLM becomes useful only when you anchor it with documentation. The constraints you feed it determine whether it behaves like a helper or a hallucination engine.

AI is becoming more diluted each year because the volume of legacy data keeps growing faster than the volume of modern examples. The next generation of coding assistants will need to treat documentation as a first-class input rather than a suggestion. And developers will need to keep producing high-quality documentation so the tools have something worth learning from.

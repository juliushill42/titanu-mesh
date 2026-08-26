TitanU / WeCanMesh — How This Actually Works
The one-sentence version

You turned a bunch of old laptops into your own private ChatGPT, and built three small programs that let them work together as one brain.
The three pieces, explained like you're new here

Think of it like a restaurant.
Piece 1: The Auto-Provisioner (titan_provision.sh)

What it really is: the hiring process for a new kitchen.

When you get a new laptop and want it to join your AI cluster, you don't want to manually install 5 different programs and configure them by hand. So this script does it for you. You run one command, and it:

    Connects the laptop to your private network (so it can only be reached by your other devices, never the public internet)
    Installs the AI engine (Ollama — this is the thing that actually runs the AI model and generates answers)
    Installs a small translator program (the "shim") so any app that expects to talk to OpenAI can talk to your laptop instead, and it won't know the difference
    Tells your control room "hey, I'm online and ready to help"

Analogy: It's like a new hire walking in, getting their badge, putting on their uniform, and clocking in — all in one motion, instead of you walking them through it step by step.
Piece 2: The Control Plane (titan_controlplane.html)

What it really is: the kitchen's security camera + order screen, combined.

This is the dashboard. It's the thing you actually look at. It shows you:

    Which laptops ("nodes") are online right now
    How hard each one is working (CPU/RAM bars — basically "how tired is this laptop")
    What AI models are loaded on each one
    A chat box where you can type a question and watch which laptop answers it

Analogy: Imagine a wall of TV screens in a restaurant kitchen showing which chefs are free, which are busy, and a ticket window where orders come in. That's this dashboard, just for AI instead of food.

Right now it's a demo — the "AI answers" are pretend (canned responses) so you can show it off without needing all 4 laptops running. There's one clearly marked spot in the code where you swap the pretend answers for real ones once your laptops are actually online.
Piece 3: The Gateway (titan_gateway.go)

What it really is: the host stand at the front of the restaurant.

This is the single doorway that the outside world uses to talk to your whole cluster. Instead of someone needing to know "talk to laptop A for this, laptop B for that," they just talk to one address, and the Gateway decides which laptop should actually handle the request.

It does three jobs:

    Picks the least-busy laptop to send each question to (so one laptop doesn't get overloaded while another sits idle)
    Checks every 10 seconds that each laptop is still alive and responding. If one goes offline, the Gateway quietly stops sending it work.
    Tries again automatically if a laptop fails to answer — it'll retry on a different one instead of just giving up.

Analogy: You walk into a restaurant, the host says "table for one, this way" and seats you with whichever server is free — you never had to know which servers exist or who's busy. That's what the Gateway does for AI requests.
How they connect, start to finish

   YOU (or an app)
        |
        |  sends a question to ONE address
        v
  ┌─────────────────┐
  │   GATEWAY        │   <- the host stand
  │ (Piece 3)         │      picks a free laptop
  └─────────────────┘
        |
        v
  ┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
  │  Laptop A        │      │  Laptop B        │      │  Laptop C        │
  │ (provisioned     │      │ (provisioned     │      │ (provisioned     │
  │  by Piece 1)      │      │  by Piece 1)      │      │  by Piece 1)      │
  └─────────────────┘      └─────────────────┘      └─────────────────┘
        ^                         ^                         ^
        └─────────────────────────┴─────────────────────────┘
                    All watched by the
              CONTROL PLANE DASHBOARD (Piece 2)

    Piece 1 is how a laptop joins the team.
    Piece 2 is how you watch the team work.
    Piece 3 is how anyone else (an app, a customer, a script) talks to the team without needing to know it's a team at all — to them it just looks like one AI.

Words you'll see and what they actually mean
Term 	What it actually means
Node 	One of your laptops/devices once it's joined the cluster. Just a fancy word for "a computer that's part of the team."
Mesh 	The private network connecting all your devices. Like a group chat, but for computers, that strangers can't read.
Mesh IP 	The private "phone number" each laptop gets on that network (always starts with 100.) — only reachable by your other devices.
Ollama 	The actual AI engine. This is the thing that reads your question and writes an answer, running entirely on the laptop, no internet needed.
The shim 	A tiny translator. Apps built for ChatGPT expect a specific format. The shim makes your laptop "speak" that same format so nothing else needs to change.
API / endpoint 	A fancy word for "an address you send a request to." /v1/chat/completions is just the specific address you send a question to.
Health check 	The Gateway poking each laptop every 10 seconds and asking "you still there?"
Failover 	If a laptop doesn't answer, automatically asking a different one instead of giving up.
Auth key / API key 	A password. If you don't set one, anyone who finds the address can use your cluster for free. Always set one before going public.
Sovereign AI 	AI that runs on hardware you own, where your data never leaves your own devices. The opposite of "send your data to a big company's cloud."
What "done" looks like

You'll know the whole thing is working when:

    You run the Provisioner on a laptop → it shows up in 30 seconds
    You open the Control Plane dashboard → that laptop appears as a green "online" card
    You type a question into the dashboard → it shows a real answer (not the canned demo text) coming from that exact laptop
    You hit the Gateway's address from a totally different device → it routes you to whichever laptop is free, and you can't tell it's not just "one big AI"

That's the whole system. Three programs, one job each, no single piece doing everything.

ExUnit.start(capture_log: true, exclude: [:integration])
Mox.defmock(Planck.Agent.MockAI, for: Planck.Agent.AIBehaviour)

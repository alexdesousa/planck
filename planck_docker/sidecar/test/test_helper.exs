ExUnit.start(exclude: [:integration])

Mox.defmock(Planck.Agent.MockAI, for: Planck.Agent.AIBehaviour)
Application.put_env(:planck_agent, :ai_client, Planck.Agent.MockAI)

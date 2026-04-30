ExUnit.start(capture_log: true)
Mox.defmock(Planck.AI.MockReqLLM, for: Planck.AI.ReqLLMBehaviour)
Mox.defmock(Planck.AI.MockHTTPClient, for: Planck.AI.HTTPClient)

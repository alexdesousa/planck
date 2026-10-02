%{
  configs: [
    %{
      name: "default",
      checks: [
        {Credo.Check.Warning.StructFieldAmount, max_fields: 32}
      ]
    }
  ]
}

using Documenter
using Decimals

makedocs(;
    modules=[Decimals],
    sitename="Decimals.jl",
    authors="Jacob Quinn and contributors",
    # set explicitly so the build works from a checkout without an origin remote
    repo=Documenter.Remotes.GitHub("JuliaMath", "Decimals.jl"),
    format=Documenter.HTML(;
        canonical="https://JuliaMath.github.io/Decimals.jl",
        prettyurls=get(ENV, "CI", "false") == "true",
        edit_link="main",
    ),
    pages=[
        "Home" => "index.md",
        "Manual" => "manual.md",
        "Semantics" => "semantics.md",
        "Migration from 0.x" => "migration.md",
        "API Reference" => "api.md",
    ],
    doctest=false,
)

deploydocs(;
    repo="github.com/JuliaMath/Decimals.jl.git",
    devbranch="main",
    push_preview=true,
)

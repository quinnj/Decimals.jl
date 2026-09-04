using Documenter
using Decimals

DocMeta.setdocmeta!(Decimals, :DocTestSetup, :(using Decimals); recursive=true)

makedocs(;
    modules=[Decimals],
    sitename="Decimals.jl",
    authors="Jacob Quinn and contributors",
    # set explicitly so the build works from a checkout without an origin remote
    repo=Documenter.Remotes.GitHub("JuliaMath", "Decimals.jl"),
    format=Documenter.HTML(;
        canonical="https://JuliaMath.github.io/Decimals.jl/stable/",
        prettyurls=true,
        edit_link="master",
    ),
    pages=[
        "Home" => "index.md",
        "Manual" => "manual.md",
        "Semantics" => "semantics.md",
        "Migration from 0.x" => "migration.md",
        "API Reference" => "api.md",
    ],
    doctest=true,
)

deploydocs(;
    repo="github.com/JuliaMath/Decimals.jl.git",
    devbranch="master",
    push_preview=true,
)

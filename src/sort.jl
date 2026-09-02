# Sorting: a decimal vector orders exactly like its coefficient vector, so the
# order-preserving UInt mapping that lets Base radix-sort machine integers is
# forwarded to the coefficient. Base derives the reverse ordering itself.
const _SortableInt = Union{Int32, Int64, Int128}

Base.Sort.UIntMappable(::Type{Decimal{P, S, T}},
                       o::Base.Order.ForwardOrdering) where {P, S, T <: _SortableInt} =
    Base.Sort.UIntMappable(T, o)
Base.Sort.uint_map(x::Decimal{P, S, T},
                   o::Base.Order.ForwardOrdering) where {P, S, T <: _SortableInt} =
    Base.Sort.uint_map(x.unscaled, o)
Base.Sort.uint_unmap(::Type{Decimal{P, S, T}}, u::Unsigned,
                     o::Base.Order.ForwardOrdering) where {P, S, T <: _SortableInt} =
    reinterpret(Decimal{P, S, T}, Base.Sort.uint_unmap(T, u, o))

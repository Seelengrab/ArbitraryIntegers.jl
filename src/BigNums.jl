module BigNums

import Base.Checked.add_with_overflow

export ArbInt

abstract type AbstractArbitInt end

struct ArbInt{T <: Union{AbstractArbitInt, UInt}} <: AbstractArbitInt
    elems::Array{UInt, 1}
    size::T
end

ArbInt(;sizehint = one(UInt)) = ArbInt(zeros(UInt, sizehint), sizehint)
ArbInt(x::UInt) = ArbInt(UInt[x], one(UInt))
ArbInt(elems::Array{UInt, 1}) = begin
    sanitizedElems = elems[findfirst(!iszero, elems):end]
    ArbInt(sanitizedElems, UInt(length(sanitizedElems)))
end

Base.zero(::Type{ArbInt}) = ArbInt(zero(UInt))
Base.one(::Type{ArbInt}) = ArbInt(one(UInt))
Base.zero(::ArbInt) = ArbInt(zero(UInt))
Base.one(::ArbInt) = ArbInt(one(UInt))

Base.leading_zeros(a::ArbInt) = leading_zeros(a.elems[1])
Base.leading_ones(a::ArbInt) = leading_ones(a.elems[1])
Base.iszero(a::ArbInt) = a.size == 1 && iszero(a.elems[1])
Base.isone(a::ArbInt) = a.size == 1 && isone(a.elems[1])

Base.deepcopy(a::ArbInt) = ArbInt(deepcopy(a.elems), deepcopy(a.size))

Base.:(==)(a::ArbInt, b::ArbInt) = a.size == b.size && a.elems == b.elems

Base.show(io::IO, a::ArbInt) = print(io, a.size, ':', a.elems)
Base.bitstring(a::ArbInt) = mapreduce(bitstring, *, a.elems)

### ADDITION ###

function Base.:+(a::ArbInt, b::UInt)
    nsize = a.elems[1] == typemax(eltype(a.elems)) ? a.size + 1 : a.size # FIXME: Check for overflow
    c = ArbInt(sizehint = nsize)
    elem, carry = add_with_overflow(a.elems[end], b)
    c.elems[end] = elem

    idx = 1 # we already computed c.elems[end - 0]
    while idx < a.size
        if carry
            c.elems[end - idx], carry = add_with_overflow(a.elems[end - idx], one(UInt))
        else
            c.elems[end - idx] = a.elems[end - idx]
        end
        idx += 1
    end

    if carry
        c.elems[1] += one(UInt)
    end

    return c
end
Base.:+(b::UInt, a::ArbInt) = a + b

function Base.:+(a::ArbInt, b::ArbInt)
    if (a.size >= b.size)
        return _add(a, b)
    else
        return _add(b, a)
    end
end

function _add(a::ArbInt, b::ArbInt)
    if iszero(b)
        return deepcopy(a)
    end

    # we only need possibly more space if the most significant word is a typemax
    # this can lead to one unnecessary word, if no overflow occurs

    # b.size <= a.size is guaranteed
    # FIXME: We only need this sometimes
    nsize = a.size + 1 # FIXME: Check for overflow
    c = zeros(UInt, nsize)

    carry = false
    idx = 0
    while idx < a.size
        if carry
            if idx < b.size
                ibt, nc = add_with_overflow(a.elems[end - idx], b.elems[end - idx])
                c[end - idx], carry = add_with_overflow(ibt, one(UInt))

                # we don't know if adding the elements or adding the previous carry overflowed
                carry = carry || nc
            else
                c[end - idx], carry = add_with_overflow(a.elems[end - idx], one(UInt))
            end
        else
            if idx < b.size
                c[end - idx], carry = add_with_overflow(a.elems[end - idx],
                                                              b.elems[end - idx])
            else
                c[end - idx] = a.elems[end - idx]
            end
        end

        idx += 1
    end

    if carry
        c[1] += one(UInt)
    end

    # FIXME: I'd rather not mutate this
    if iszero(c[1])
        popfirst!(c)
        nsize -= 1
    end

    return ArbInt(c, nsize)
end

### SUBTRACTION ###

# TODO: Implement signed numbers

### MULTIPLICATION ###

function Base.:*(a::ArbInt, b::UInt)
    if b == 1
        return deepcopy(a)
    elseif b == 0
        return zero(a)
    end

    shiftsize = sizeof(UInt) * 4        # equiv. to sizeof(UInt) * 8 / 2

    # For multiplication, getting the right final size is more difficult.
    # Imagine we have two numbers and multiply them, each made of two parts:
    #     aabb * ccdd
    # How big is the result? Let's look at which part is ending up where when we
    # multiply each with each and sum correctly (# denotes set bits in the upper 16/32/x bits)
    #         #oo
    #         #bd
    #      #|bc
    #      #|ad
    #    #ac|
    #  -----------
    #    #oo|ffff
    #
    # So ffff is the new number, and +oo is the possible/given overflow.
    # We get a guaranteed overflow when both aa and cc are nonzero.
    # If only one of them is zero, we might get an overflow bubbling up from below.
    # If both are zero, we won't overflow the multiplication.

    if b < (1 << shiftsize) && a.elems[1] < (1 << shiftsize)
        c = ArbInt(sizehint = a.size) # we won't overflow
    else
        # FIXME: Check for overflow and convert to ArbInt
        c = ArbInt(sizehint = a.size + 1) # we may overflow
    end

    lower = b & (typemax(UInt) >> shiftsize)
    upper = b >> shiftsize
    carry::UInt = 0
    idx = 0
    while idx < a.size
        LowLow = (a.elems[end - idx] & (typemax(UInt) >> shiftsize)) * lower
        UppLow = (a.elems[end - idx] >> shiftsize) * lower
        LowUpp = (a.elems[end - idx] & (typemax(UInt) >> shiftsize)) * upper
        UppUpp = (a.elems[end - idx] >> shiftsize) * upper

        tmp, cry1 = add_with_overflow(LowLow, UppLow << shiftsize)
        tmp, cry2 = add_with_overflow(tmp, LowUpp << shiftsize)
        tmp, cry = add_with_overflow(tmp, carry)
        c.elems[end - idx] = tmp

        carry = 0

        if cry1
            carry += 1
        end
        if cry2
            carry += 1
        end
        if cry1
            carry += 1
        end

        # these three additions should never overflow, as only the upper half of the bits are added
        # and UppUpp isn't big enough to cause overflow with the other values
        carry += UppLow >> shiftsize
        carry += LowUpp >> shiftsize
        carry += UppUpp

        idx += 1
    end

    if idx < c.size # carry not set/there is carry
        c.elems[1] = carry
    end

    return c
end
Base.:*(b::UInt, a::ArbInt) = a * b

Base.:*(a::ArbInt, b::ArbInt) = begin
    if a.size > b.size
        _mul(a, b)
    else
        _mul(b,a)
    end
end

function _mul(a::ArbInt, b::ArbInt)
    # TODO: make this faster by using a better algorithm
    # if isone(b)
    #     return deepcopy(a)
    # elseif isone(a)
    #     return deepcopy(b)
    # elseif iszero(a) || iszero(b)
    #     return zero(a)
    # end

    shiftsize = sizeof(UInt) * UInt(4)        # equiv. to sizeof(UInt) * 8 / 2

    # if b.elems[1] < (1 << shiftsize) && a.elems[1] < (1 << shiftsize)
    #     c = ArbInt(sizehint = a.size) # we won't overflow
    # else

    # FIXME: Check for overflow and convert to ArbInt
    nsize = a.size + b.size # FIXME: Check for overflow
    c = zeros(UInt, nsize)

    # c = ArbInt(sizehint = a.size + b.size) # we may overflow
    # end

    CARRY = zero(UInt)
    @inbounds for idx_b in 0:(b.size - 1)
        b_el = b.elems[end - idx_b]
        low_b::UInt = b_el & (typemax(UInt) >> shiftsize)
        upp_b::UInt = b_el >> shiftsize

        @inbounds for idx_a in 0:(a.size - 1)
            a_el = a.elems[end - idx_a]
            low_a::UInt = a_el & (typemax(UInt) >> shiftsize)
            upp_a::UInt = a_el >> shiftsize

            LowLow = low_a * low_b
            UppLow = upp_a * low_b
            LowUpp = low_a * upp_b
            UppUpp = upp_a * upp_b

            tmp, carr = add_with_overflow(LowLow, UppLow << shiftsize)
            c[end - idx_a - idx_b - 1], carr = add_with_overflow(c[end - idx_a - idx_b - 1], UInt(carr))
            CARRY += carr

            tmp, carr = add_with_overflow(tmp, LowUpp << shiftsize)
            c[end - idx_a - idx_b - 1], carr = add_with_overflow(c[end - idx_a - idx_b - 1], UInt(carr))
            CARRY += carr

            tmp, carr = add_with_overflow(tmp, c[end - idx_a - idx_b])
            c[end - idx_a - idx_b - 1], carr = add_with_overflow(c[end - idx_a - idx_b - 1], UInt(carr))
            CARRY += carr

            c[end - idx_a - idx_b] = tmp

            # these three additions should never overflow, as only the upper half of the bits are added
            # and UppUpp isn't big enough to cause overflow with the other values
            c[end - idx_a - idx_b - 1], carr = add_with_overflow(
                c[end - idx_a - idx_b - 1],
                UppLow >> shiftsize
                )
            CARRY += carr

            c[end - idx_a - idx_b - 1], carr = add_with_overflow(
                c[end - idx_a - idx_b - 1],
                LowUpp >> shiftsize
                )
            CARRY += carr

            c[end - idx_a - idx_b - 1], carr = add_with_overflow(
                c[end - idx_a - idx_b - 1],
                UppUpp >> shiftsize
                )
            CARRY += carr

            if CARRY > 0
                c[end - idx_a - idx_b - 2], CARRY = add_with_overflow(c[end - idx_a - idx_b - 2], UInt(CARRY))
            end
            CARRY != 0 && println("CARRY: $CARRY")
            CARRY = zero(UInt)

        end
    end

    while iszero(c[1]) && nsize > 1
        popfirst!(c)
        nsize -= 1
    end

    return ArbInt(c, nsize)
end

### DIVISION ###

# TODO: Implement division

### POWER ###

# TODO: Implement power function

### MODULO ###

# TODO: Implement modulo arithmetic

end # module
// UVC Expected Header Alias
// Routes to vendored tl::expected implementation
// See: DECISION-016 in adr-proposal.md

#ifndef UVC_EXPECTED_H
#define UVC_EXPECTED_H

#include "../../third_party/tl/expected.hpp"

namespace uvc {
    template<typename T, typename E>
    using expected = tl::expected<T, E>;

    using tl::unexpected;
    using tl::unexpect;
    using tl::unexpect_t;
    using tl::bad_expected_access;
}

#endif // UVC_EXPECTED_H

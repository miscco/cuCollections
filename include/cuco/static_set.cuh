/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cuco/detail/__config>
#include <cuco/detail/prime.hpp>
#include <cuco/extent.cuh>
#include <cuco/hash_functions.cuh>
#include <cuco/probing_scheme.cuh>
#include <cuco/sentinel.cuh>
#include <cuco/static_set_ref.cuh>
#include <cuco/storage.cuh>
#include <cuco/utility/allocator.hpp>
#include <cuco/utility/traits.hpp>

#include <thrust/functional.h>

#include <cuda/atomic>

#if defined(CUCO_HAS_CUDA_BARRIER)
#include <cuda/barrier>
#endif

#include <cstddef>
#include <type_traits>

namespace cuco {
namespace experimental {
/**
 * @brief A GPU-accelerated, unordered, associative container of unique keys.
 *
 * The `static_set` supports two types of operations:
 * - Host-side "bulk" operations
 * - Device-side "singular" operations
 *
 * The host-side bulk operations include `insert`, `contains`, etc. These APIs should be used when
 * there are a large number of keys to modify or lookup. For example, given a range of keys
 * specified by device-accessible iterators, the bulk `insert` function will insert all keys into
 * the set.
 *
 * The singular device-side operations allow individual threads (or cooperative groups) to perform
 * independent modify or lookup operations from device code. These operations are accessed through
 * non-owning, trivially copyable reference types (or "ref"). User can combine any arbitrary
 * operators (see options in `include/cuco/operator.hpp`) when creating the ref. Concurrent modify
 * and lookup will be supported if both kinds of operators are specified during the ref
 * construction.
 *
 * @note Allows constant time concurrent modify or lookup operations from threads in device code.
 * @note cuCollections data stuctures always place the slot keys on the left-hand side when invoking
 * the key comparison predicate, i.e., `pred(slot_key, query_key)`. Order-sensitive `KeyEqual`
 * should be used with caution.
 * @note `ProbingScheme::cg_size` indicates how many threads are used to handle one independent
 * device operation. `cg_size == 1` uses the scalar (or non-CG) code paths.
 *
 * @throw If the size of the given key type is larger than 8 bytes
 * @throw If the given key type doesn't have unique object representations, i.e.,
 * `cuco::bitwise_comparable_v<Key> == false`
 * @throw If the probing scheme type is not inherited from `cuco::detail::probing_scheme_base`
 *
 * @tparam Key Type used for keys. Requires `cuco::is_bitwise_comparable_v<Key>`
 * @tparam Extent Data structure size type
 * @tparam Scope The scope in which operations will be performed by individual threads.
 * @tparam KeyEqual Binary callable type used to compare two keys for equality
 * @tparam ProbingScheme Probing scheme (see `include/cuco/probing_scheme.cuh` for choices)
 * @tparam Allocator Type of allocator used for device storage
 * @tparam Storage Slot window storage type
 */

template <class Key,
          class Extent             = cuco::experimental::extent<std::size_t>,
          cuda::thread_scope Scope = cuda::thread_scope_device,
          class KeyEqual           = thrust::equal_to<Key>,
          class ProbingScheme      = experimental::double_hashing<1,  // CG size
                                                             cuco::murmurhash3_32<Key>,
                                                             cuco::murmurhash3_32<Key>>,
          class Allocator          = cuco::cuda_allocator<std::byte>,
          class Storage            = cuco::experimental::aow_storage<2>>
class static_set {
  static_assert(sizeof(Key) <= 8, "Container does not support key types larger than 8 bytes.");

  static_assert(
    cuco::is_bitwise_comparable_v<Key>,
    "Key type must have unique object representations or have been explicitly declared as safe for "
    "bitwise comparison via specialization of cuco::is_bitwise_comparable_v<Key>.");

  static_assert(
    std::is_base_of_v<cuco::experimental::detail::probing_scheme_base<ProbingScheme::cg_size>,
                      ProbingScheme>,
    "ProbingScheme must inherit from cuco::detail::probing_scheme_base");

 public:
  static constexpr auto cg_size      = ProbingScheme::cg_size;  ///< CG size used to for probing
  static constexpr auto window_size  = Storage::window_size;    ///< Window size used to for probing
  static constexpr auto thread_scope = Scope;                   ///< CUDA thread scope

  using key_type   = Key;  ///< Key type
  using value_type = Key;  ///< Key type
  /// Extent type
  using extent_type    = decltype(make_valid_extent<cg_size, window_size>(std::declval<Extent>()));
  using size_type      = typename extent_type::value_type;  ///< Size type
  using key_equal      = KeyEqual;                          ///< Key equality comparator type
  using allocator_type = Allocator;                         ///< Allocator type
  using storage_type =
    detail::storage<Storage, value_type, extent_type, allocator_type>;  ///< Storage type

  using storage_ref_type = typename storage_type::ref_type;  ///< Non-owning window storage ref type
  using probing_scheme_type = ProbingScheme;                 ///< Probe scheme type
  template <typename... Operators>
  using ref_type =
    cuco::experimental::static_set_ref<key_type,
                                       thread_scope,
                                       key_equal,
                                       probing_scheme_type,
                                       storage_ref_type,
                                       Operators...>;  ///< Non-owning container ref type

  static_set(static_set const&) = delete;
  static_set& operator=(static_set const&) = delete;

  static_set(static_set&&) = default;  ///< Move constructor

  /**
   * @brief Replaces the contents of the container with another container.
   *
   * @return Reference of the current map object
   */
  static_set& operator=(static_set&&) = default;
  ~static_set()                       = default;

  /**
   * @brief Constructs a statically-sized set with the specified initial capacity, sentinel values
   * and CUDA stream.
   *
   * The actual set capacity depends on the given `capacity`, the probing scheme, CG size, and the
   * window size and it's computed via `make_valid_extent` factory. Insert operations will not
   * automatically grow the set. Attempting to insert more unique keys than the capacity of the map
   * results in undefined behavior.
   *
   * The `empty_key_sentinel` is reserved and behavior is undefined when attempting to insert
   * this sentinel value.
   *
   * @param capacity The requested lower-bound set size
   * @param empty_key_sentinel The reserved key value for empty slots
   * @param pred Key equality binary predicate
   * @param probing_scheme Probing scheme
   * @param alloc Allocator used for allocating device storage
   * @param stream CUDA stream used to initialize the map
   */
  constexpr static_set(Extent capacity,
                       empty_key<Key> empty_key_sentinel,
                       KeyEqual pred                       = {},
                       ProbingScheme const& probing_scheme = {},
                       Allocator const& alloc              = {},
                       cudaStream_t stream                 = nullptr);

  /**
   * @brief Inserts all keys in the range `[first, last)` and returns the number of successful
   * insertions.
   *
   * @note This function synchronizes the given stream. For asynchronous execution use
   * `insert_async`.
   *
   * @tparam InputIt Device accessible random access input iterator where
   * <tt>std::is_convertible<std::iterator_traits<InputIt>::value_type,
   * static_set<K>::value_type></tt> is `true`
   *
   * @param first Beginning of the sequence of keys
   * @param last End of the sequence of keys
   * @param stream CUDA stream used for insert
   *
   * @return Number of successfully inserted keys
   */
  template <typename InputIt>
  size_type insert(InputIt first, InputIt last, cudaStream_t stream = nullptr);

  /**
   * @brief Asynchonously inserts all keys in the range `[first, last)`.
   *
   * @tparam InputIt Device accessible random access input iterator where
   * <tt>std::is_convertible<std::iterator_traits<InputIt>::value_type,
   * static_set<K>::value_type></tt> is `true`
   *
   * @param first Beginning of the sequence of keys
   * @param last End of the sequence of keys
   * @param stream CUDA stream used for insert
   */
  template <typename InputIt>
  void insert_async(InputIt first, InputIt last, cudaStream_t stream = nullptr);

  /**
   * @brief Indicates whether the keys in the range `[first, last)` are contained in the set.
   *
   * @note This function synchronizes the given stream. For asynchronous execution use
   * `contains_async`.
   *
   * @tparam InputIt Device accessible input iterator
   * @tparam OutputIt Device accessible output iterator assignable from `bool`
   *
   * @param first Beginning of the sequence of keys
   * @param last End of the sequence of keys
   * @param output_begin Beginning of the sequence of booleans for the presence of each key
   * @param stream Stream used for executing the kernels
   */
  template <typename InputIt, typename OutputIt>
  void contains(InputIt first,
                InputIt last,
                OutputIt output_begin,
                cudaStream_t stream = nullptr) const;

  /**
   * @brief Asynchonously indicates whether the keys in the range `[first, last)` are contained in
   * the set.
   *
   * @tparam InputIt Device accessible input iterator
   * @tparam OutputIt Device accessible output iterator assignable from `bool`
   *
   * @param first Beginning of the sequence of keys
   * @param last End of the sequence of keys
   * @param output_begin Beginning of the sequence of booleans for the presence of each key
   * @param stream Stream used for executing the kernels
   */
  template <typename InputIt, typename OutputIt>
  void contains_async(InputIt first,
                      InputIt last,
                      OutputIt output_begin,
                      cudaStream_t stream = nullptr) const;

  /**
   * @brief Gets the number of elements in the container.
   *
   * @note This function synchronizes the given stream.
   *
   * @param stream CUDA stream used to get the number of inserted elements
   * @return The number of elements in the container
   */
  [[nodiscard]] size_type size(cudaStream_t stream = nullptr) const;

  /**
   * @brief Gets the maximum number of elements the hash map can hold.
   *
   * @return The maximum number of elements the hash map can hold
   */
  [[nodiscard]] constexpr auto capacity() const noexcept;

  /**
   * @brief Gets the sentinel value used to represent an empty key slot.
   *
   * @return The sentinel value used to represent an empty key slot
   */
  [[nodiscard]] constexpr key_type empty_key_sentinel() const noexcept;

  /**
   * @brief Get device ref with operators.
   *
   * @tparam Operators Set of `cuco::op` to be provided by the ref
   *
   * @param ops List of operators, e.g., `cuco::insert`
   *
   * @return Device ref of the current `static_set` object
   */
  template <typename... Operators>
  [[nodiscard]] auto ref(Operators... ops) const noexcept;

 private:
  key_type empty_key_sentinel_;         ///< Key value that represents an empty slot
  key_equal predicate_;                 ///< Key equality binary predicate
  probing_scheme_type probing_scheme_;  ///< Probing scheme
  allocator_type allocator_;            ///< Allocator used to (de)allocate temporary storage
  storage_type storage_;                ///< Slot window storage
};

}  // namespace experimental
}  // namespace cuco

#include <cuco/detail/static_set/static_set.inl>
#include "sighter/graphics/vulkan_text_overlay_compositor.h"

#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>

namespace sighter {
namespace graphics {
namespace {

std::atomic<int> g_submit_calls{0};
std::atomic<int> g_submit2_calls{0};
std::atomic<int> g_bind_sparse_calls{0};
std::atomic<int> g_wait_idle_calls{0};
std::atomic<VkQueue> g_last_queue{VK_NULL_HANDLE};

VkQueue FakeQueue() {
  return reinterpret_cast<VkQueue>(static_cast<uintptr_t>(0x51b));
}

VkResult RecordingQueueSubmit(VkQueue queue, uint32_t, const VkSubmitInfo*,
                              VkFence) {
  g_submit_calls.fetch_add(1, std::memory_order_relaxed);
  g_last_queue.store(queue, std::memory_order_relaxed);
  return VK_SUCCESS;
}

VkResult RecordingQueueSubmit2(VkQueue queue, uint32_t, const VkSubmitInfo2*,
                               VkFence) {
  g_submit2_calls.fetch_add(1, std::memory_order_relaxed);
  g_last_queue.store(queue, std::memory_order_relaxed);
  return VK_SUCCESS;
}

VkResult RecordingQueueBindSparse(VkQueue queue, uint32_t,
                                  const VkBindSparseInfo*, VkFence) {
  g_bind_sparse_calls.fetch_add(1, std::memory_order_relaxed);
  g_last_queue.store(queue, std::memory_order_relaxed);
  return VK_SUCCESS;
}

VkResult RecordingQueueWaitIdle(VkQueue queue) {
  g_wait_idle_calls.fetch_add(1, std::memory_order_relaxed);
  g_last_queue.store(queue, std::memory_order_relaxed);
  return VK_SUCCESS;
}

class VulkanTextOverlayCompositorTest : public ::testing::Test {
 protected:
  void SetUp() override {
    g_submit_calls.store(0, std::memory_order_relaxed);
    g_submit2_calls.store(0, std::memory_order_relaxed);
    g_bind_sparse_calls.store(0, std::memory_order_relaxed);
    g_wait_idle_calls.store(0, std::memory_order_relaxed);
    g_last_queue.store(VK_NULL_HANDLE, std::memory_order_relaxed);
  }
};

TEST_F(VulkanTextOverlayCompositorTest,
       InactiveOverlayQueueSubmitInvokesFallback) {
  VulkanTextOverlayCompositor compositor;
  const VkQueue queue = FakeQueue();
  EXPECT_EQ(compositor.QueueSubmit(queue, 0, nullptr, VK_NULL_HANDLE,
                                   RecordingQueueSubmit),
            VK_SUCCESS);
  EXPECT_EQ(g_submit_calls.load(std::memory_order_relaxed), 1);
  EXPECT_EQ(g_last_queue.load(std::memory_order_relaxed), queue);
}

TEST_F(VulkanTextOverlayCompositorTest,
       InactiveOverlayQueueSubmit2WaitIdleAndBindSparseInvokeFallback) {
  VulkanTextOverlayCompositor compositor;
  const VkQueue queue = FakeQueue();
  EXPECT_EQ(compositor.QueueSubmit2(queue, 0, nullptr, VK_NULL_HANDLE,
                                    RecordingQueueSubmit2),
            VK_SUCCESS);
  EXPECT_EQ(compositor.QueueBindSparse(queue, 0, nullptr, VK_NULL_HANDLE,
                                       RecordingQueueBindSparse),
            VK_SUCCESS);
  EXPECT_EQ(compositor.QueueWaitIdle(queue, RecordingQueueWaitIdle),
            VK_SUCCESS);
  EXPECT_EQ(g_submit2_calls.load(std::memory_order_relaxed), 1);
  EXPECT_EQ(g_bind_sparse_calls.load(std::memory_order_relaxed), 1);
  EXPECT_EQ(g_wait_idle_calls.load(std::memory_order_relaxed), 1);
  EXPECT_EQ(g_last_queue.load(std::memory_order_relaxed), queue);
}

TEST_F(VulkanTextOverlayCompositorTest, NullFallbackFailsClosed) {
  VulkanTextOverlayCompositor compositor;
  const VkQueue queue = FakeQueue();
  EXPECT_EQ(
      compositor.QueueSubmit(queue, 0, nullptr, VK_NULL_HANDLE, nullptr),
      VK_ERROR_INITIALIZATION_FAILED);
  EXPECT_EQ(
      compositor.QueueSubmit2(queue, 0, nullptr, VK_NULL_HANDLE, nullptr),
      VK_ERROR_INITIALIZATION_FAILED);
  EXPECT_EQ(
      compositor.QueueBindSparse(queue, 0, nullptr, VK_NULL_HANDLE, nullptr),
      VK_ERROR_INITIALIZATION_FAILED);
  EXPECT_EQ(compositor.QueueWaitIdle(queue, nullptr),
            VK_ERROR_INITIALIZATION_FAILED);
  EXPECT_EQ(g_submit_calls.load(std::memory_order_relaxed), 0);
}

}  // namespace
}  // namespace graphics
}  // namespace sighter

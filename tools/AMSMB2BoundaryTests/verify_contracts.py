"""Narrow source invariants; these are not network or device acceptance tests."""
from pathlib import Path
import argparse
import hashlib
import json

source = Path(__file__).resolve().parents[2]
dependency = source / "Dependencies/AMSMB2"
baseline = json.loads(Path(__file__).with_name("dependency-baseline.json").read_text())
manager = (dependency / "AMSMB2/AMSMB2.swift").read_text()
context = (dependency / "AMSMB2/Context.swift").read_text()
file_handle = (dependency / "AMSMB2/FileHandle.swift").read_text()
checks = {}

fresh = manager.split("open func connectShareOnce(", 1)[1].split("/// Async form", 1)[0]
checks["fresh_connect_calls_connect_exactly_once"] = fresh.count("self.connect(shareName:") == 1
checks["fresh_connect_has_no_echo_or_retry"] = ".echo(" not in fresh and "catch" not in fresh
checks["fresh_connect_requires_no_existing_client"] = "guard self.client == nil" in fresh
connect = manager.split("private func connect(shareName:", 1)[1].split("private func with(", 1)[0]
checks["fresh_connect_uses_existing_security_initialization"] = "initClient(client, encrypted: encrypted)" in connect
retire = manager.split("open func retireLocallyAfterDraining(completionHandler:", 1)[1].split("/// Async local retirement", 1)[0]
checks["retirement_drains_before_connect_lock"] = retire.index("while self.operationCount > 0") < retire.index("self.connectLock.lock()")
checks["retirement_destroys_then_clears_client"] = retire.index("invalidateLocally()") < retire.index("self.client = nil")
checks["retirement_has_no_network_disconnect"] = ".disconnect(" not in retire and "disconnectShare(" not in retire
queue = manager.split("private func queue(", 1)[1].split("private func initClient(", 1)[0]
checks["operation_count_decreases_after_callback_closure_returns"] = queue.index("closure()") < queue.index("self.operationCount -= 1")
service = context.split("func handleServiceResult(", 1)[1].split("// MARK: Connectivity", 1)[0]
checks["every_negative_service_result_invalidates"] = "guard result < 0" in service and "invalidateLocally()" in service and ".serviceInvalidated, result: result" in service
checks["service_failure_does_not_read_stale_ntstatus_or_convert_to_posix"] = all(word not in service for word in ["ntError", "errno", "POSIXError", "description: error"])
generic = context.split("static let generic_handler:", 1)[1].split("typealias ContextHandler", 1)[0]
checks["generic_callback_checks_fd_before_callback_data"] = generic.index("pointee.fd >= 0") < generic.index("cbdata.unwrap()")
wait = context.split("private func wait_for_reply(", 1)[1].split("static let generic_handler:", 1)[0]
checks["poll_preserves_existing_1000ms_interval_and_timeout_comparison"] = "poll(&pfd, 1, 1000)" in wait and "Date().timeIntervalSince(startDate) > timeout" in wait
checks["poll_errno_is_current_os_errno"] = "Darwin.errno" in wait and "Glibc.errno" in wait
checks["both_wait_failures_destroy_before_pointer_scope_exit"] = context.count("""try wait_for_reply(callback.pointee)
                } catch {
                    invalidateLocally()
                    throw error
                }""") == 2
checks["both_pointer_scopes_cover_submission_and_wait"] = context.count("try withUnsafeMutablePointer(to: &cb) { callback in") == 2 and "wait_for_reply(&cb)" not in context
directory = manager.split("private func listDirectory(client:", 1)[1].split("private func recursiveCopyIterator(", 1)[0]
checks["directory_snapshot_lock_covers_open_iteration_and_owned_values"] = directory.index("var contents = try client.withThreadSafeContext") < directory.index("let dir = try SMB2Directory") < directory.index("for ent in dir") < directory.index("String(cString: ent.name)") < directory.index("return contents") < directory.index("if recursive")
checks["directory_has_one_construction_site"] = manager.count("SMB2Directory(") == 1
checks["file_handle_has_no_unlocked_client_context_access"] = "client.context" not in file_handle
checks["file_descriptor_read_uses_context_lifetime_lock"] = "return try withThreadSafeContext(smb2_get_fd)" in context
ioctl = file_handle.split("var inputBuffer = [UInt8](args)", 1)[1].split("func fcntl<DataType:", 1)[0]
checks["ioctl_metadata_is_built_inside_locked_async_handler"] = ioctl.index("client.async_await_pdu") < ioctl.index("var req = smb2_ioctl_request") < ioctl.index("output_offset: 0, output_count: UInt32(client.maximumTransactionSize)")
for method, following in [("func read(length:", "func pread(offset:"), ("func pread(offset:", "var maxWriteSize:")]:
    body = file_handle.split(method, 1)[1].split(following, 1)[0]
    checks[method.split("(")[0].replace(" ", "_") + "_guards_context_before_default_buffer_size"] = body.index("client.withThreadSafeContext") < body.index("let count =") < body.index("Data(repeating:")

c_files = {p: sha for p, sha in baseline.items() if p.startswith("Dependencies/AMSMB2/Dependencies/libsmb2/")}
checks["all_baseline_libsmb2_files_unchanged"] = bool(c_files) and all(hashlib.sha256((source / p).read_bytes()).hexdigest() == sha for p, sha in c_files.items())
checks["build63_socket_nosigpipe_unchanged"] = hashlib.sha256((dependency / "Dependencies/libsmb2/lib/socket.c").read_bytes()).hexdigest() == baseline["Dependencies/AMSMB2/Dependencies/libsmb2/lib/socket.c"]
for name in ["Package.swift", "Package@swift-6.0.swift"]:
    relative = "Dependencies/AMSMB2/" + name
    checks["dependency_manifest_unchanged_" + name] = hashlib.sha256((source / relative).read_bytes()).hexdigest() == baseline[relative]

persistent = manager.split("// MARK: Narrow persistent read-only playback API", 1)[1]
checks["playback_open_read_access_all_share_flags_open_only"] = "desiredAccess: [.readData, .fileReadEA, .fileReadAttributes]" in persistent and "shareAccess: [.read, .write, .delete]" in persistent and "createDisposition: .open" in persistent
checks["playback_open_holds_context_across_create_and_initial_fstat"] = persistent.index("return try originalClient.withThreadSafeContext") < persistent.index("file = try SMB2FileHandle") < persistent.index("try file.readOnlyOperation { try file.fstat() }")
checks["playback_open_no_reconnect"] = "self.connect(" not in persistent and "connectShare(" not in persistent
checks["playback_operations_counted_before_enqueue_and_after_callback"] = persistent.index("operationCount += 1") < persistent.index("queue.async") < persistent.index("body()") < persistent.index("operationCount -= 1")
checks["playback_close_uses_original_context_and_generation"] = "client.fileHandleGeneration == readOnlyGeneration" in file_handle and "try client.async_await" in file_handle.split("func closeReadOnlyThrowing()", 1)[1].split("func readOnlyOperation", 1)[0]
checks["disconnect_invalidates_generation_before_freeing_handles"] = context.index("fileHandleGeneration &+= 1", context.index("func disconnect()")) < context.index("smb2_free_all_fhs(context)")
checks["playback_bounded_loop_and_cancellation"] = "2 * 1024 * 1024" in persistent and "offset += UInt64(data.count)" in persistent and "try checkCancellation()" in persistent
checks["playback_no_actor_blocking_io"] = "actor " not in persistent and 'DispatchQueue(label: "AMSMB2.read-only-handle")' in persistent

result = {"checks": checks, "passed": sum(checks.values()), "total": len(checks)}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=Path(__file__).parent / ".build/source-contracts.json")
output = parser.parse_args().output
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
assert all(checks.values())

# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'open3'
require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Counts the ESTABLISHED TCP connections of a process for ResourceMonitor: from `/proc` on Linux, from
    # `lsof` elsewhere.
    module ConnectionCounter
      extend T::Sig

      # Aggregates physical network sockets representing valid ESTABLISHED system patterns cleanly without collision.
      #
      # @param pid [Integer, nil] OS map matching tracking subsystem explicitly
      # @return [Integer] sum total connected target bound structures natively
      sig { params(pid: T.nilable(Integer)).returns(Integer) }
      def count_established_connections(pid)
        return 0 if pid.nil?

        if File.directory?("/proc/#{pid}/fd")
          count_linux_connections(pid)
        else
          count_lsof_connections(pid)
        end
      rescue StandardError
        0
      end

      private

      # Counts only ESTABLISHED TCP sockets on Linux, matching the macOS `lsof` path.
      # A bare `socket:[` prefix would over-count listening/UNIX/UDP sockets, so we
      # intersect the process's socket fds with the inodes of ESTABLISHED entries in
      # `/proc/<pid>/net/tcp[6]` (state `01`).
      #
      # @param pid [Integer] physical identifier dynamically mapped logically
      # @return [Integer] count of established TCP connections
      sig { params(pid: Integer).returns(Integer) }
      def count_linux_connections(pid)
        established = established_inodes(pid)
        fd_socket_inodes(pid).count { |inode| established.include?(inode) }
      end

      # Resolves every file descriptor of the process to its socket inode, dropping descriptors
      # that are not sockets (and any that vanish mid-walk: a readlink on a since-closed fd raises
      # and is skipped rather than aborting the whole count).
      #
      # @param pid [Integer] tracked process identifier
      # @return [Array<String>] socket inode strings for the process's socket fds
      sig { params(pid: Integer).returns(T::Array[String]) }
      def fd_socket_inodes(pid)
        Dir.glob("/proc/#{pid}/fd/*").filter_map do |fd_path|
          socket_inode(fd_path)
        rescue StandardError
          nil
        end
      end

      # Extracts the socket inode from a single `/proc/<pid>/fd/<n>` symlink target, or nil when the
      # descriptor is not a socket. The `\A...\z` anchors reject non-socket targets (pipes, files,
      # `socket:[` substrings) so only a bare `socket:[<inode>]` link yields an inode.
      #
      # @param fd_path [String] absolute path of the file-descriptor symlink
      # @return [String, nil] the socket inode, or nil when the target is not a socket link
      sig { params(fd_path: String).returns(T.nilable(String)) }
      def socket_inode(fd_path)
        File.readlink(fd_path).match(/\Asocket:\[(\d+)\]\z/)&.[](1)
      end

      # Collects the socket inodes of ESTABLISHED TCP (IPv4 + IPv6) connections owned
      # by the process, parsed from `/proc/<pid>/net/tcp` and `net/tcp6`.
      #
      # @param pid [Integer] tracked process identifier
      # @return [Array<String>] inode strings of ESTABLISHED sockets
      sig { params(pid: Integer).returns(T::Array[String]) }
      def established_inodes(pid)
        %w[tcp tcp6].flat_map do |proto|
          path = "/proc/#{pid}/net/#{proto}"
          next [] unless File.exist?(path)

          # The header row's state column is never '01', so it is filtered out like any other
          # non-ESTABLISHED row; no explicit header drop is needed. Each data row has >= 10
          # whitespace fields, so `fetch` is total.
          File.read(path).each_line.filter_map do |line|
            cols = line.split
            cols.fetch(9) if cols.fetch(3) == '01'
          end
        end
      end

      # Leverages legacy UNIX tooling safely generating mapped logic structures universally.
      #
      # @param pid [Integer] ID
      # @return [Integer] connections count actively evaluated
      sig { params(pid: Integer).returns(Integer) }
      def count_lsof_connections(pid)
        out, _s = Open3.capture2('lsof', '-p', pid.to_s, '-n', '-P')
        out.lines.count { |line| line.include?('(ESTABLISHED)') }
      end
    end
  end
end

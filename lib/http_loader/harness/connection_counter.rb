# typed: strong
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'open3'
require 'sorbet-runtime'

# Primary namespace for the load testing framework.
module HttpLoader
  class Harness
    # Counts the ESTABLISHED TCP connections of a process: from `/proc` on Linux, from `lsof` elsewhere.
    module ConnectionCounter
      extend T::Sig

      # The established TCP connections of a process.
      #
      # @param pid [Integer, nil] the process, or nil for an external one
      # @return [Integer] the count; 0 for an external process or when it cannot be read
      sig { params(pid: T.nilable(Integer)).returns(Integer) }
      def self.count(pid)
        return 0 unless pid

        File.directory?("/proc/#{pid}/fd") ? count_linux(pid) : count_lsof(pid)
      rescue StandardError
        0
      end

      # Counts only ESTABLISHED TCP sockets on Linux, matching the macOS `lsof` path.
      # A bare `socket:[` prefix would over-count listening/UNIX/UDP sockets, so the
      # process's socket fds are intersected with the inodes of ESTABLISHED entries in
      # `/proc/<pid>/net/tcp[6]` (state `01`).
      #
      # @param pid [Integer] the process
      # @return [Integer] count of established TCP connections
      sig { params(pid: Integer).returns(Integer) }
      def self.count_linux(pid)
        established = %w[tcp tcp6].flat_map { |proto| established_inodes("/proc/#{pid}/net/#{proto}") }
        fd_socket_inodes(pid).count { |inode| established.include?(inode) }
      end

      # Resolves every file descriptor of the process to its socket inode, dropping descriptors
      # that are not sockets (and any that vanish mid-walk: a readlink on a since-closed fd raises
      # and is skipped rather than aborting the whole count).
      #
      # @param pid [Integer] the process
      # @return [Array<String>] socket inode strings for the process's socket fds
      sig { params(pid: Integer).returns(T::Array[String]) }
      def self.fd_socket_inodes(pid)
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
      def self.socket_inode(fd_path)
        File.readlink(fd_path).match(/\Asocket:\[(\d+)\]\z/)&.[](1)
      end

      # The socket inodes of the ESTABLISHED connections in one `/proc/<pid>/net/tcp[6]` table.
      #
      # @param path [String] the table
      # @return [Array<String>] the inodes; none when the table does not exist
      sig { params(path: String).returns(T::Array[String]) }
      def self.established_inodes(path)
        return [] unless File.exist?(path)

        File.read(path).each_line.filter_map { |line| established_inode(line) }
      end

      # The socket inode of one row of a TCP table when the connection is ESTABLISHED (state `01`). The header
      # row's state column is never '01', so it is filtered out like any other row; every row has at least
      # 10 whitespace-separated fields, so `fetch` is total.
      #
      # @param line [String] the row
      # @return [String, nil] the inode, or nil for another state
      sig { params(line: String).returns(T.nilable(String)) }
      def self.established_inode(line)
        cols = line.split
        cols.fetch(9) if cols.fetch(3) == '01'
      end

      # Counts the ESTABLISHED connections `lsof` lists for the process.
      #
      # @param pid [Integer] the process
      # @return [Integer] connections count
      sig { params(pid: Integer).returns(Integer) }
      def self.count_lsof(pid)
        out, _status = Open3.capture2('lsof', '-p', pid.to_s, '-n', '-P')
        out.lines.count { |line| line.include?('(ESTABLISHED)') }
      end
      private_class_method :count_linux,
        :fd_socket_inodes,
        :socket_inode,
        :established_inodes,
        :established_inode,
        :count_lsof
    end
  end
end

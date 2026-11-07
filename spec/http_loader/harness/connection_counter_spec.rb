# typed: true
# frozen_string_literal: true

# Copyright (c) 2026 Vitalii Lazebnyi

require 'spec_helper'

RSpec.describe(HttpLoader::Harness::ConnectionCounter) do
  # The connection counter is mixed into the resource monitor, whose getconf constants are resolved at construction.
  let(:counter) { HttpLoader::Harness::ResourceMonitor.new }

  before { allow(Open3).to(receive(:capture2).with('getconf', anything).and_return(["4096\n", nil])) }

  describe '#count_established_connections' do
    it 'returns zero for a nil pid without probing /proc or lsof', :aggregate_failures do
      allow(File).to(receive(:directory?).and_call_original)
      expect(counter.count_established_connections(nil)).to(eq(0))
      expect(File).not_to(have_received(:directory?))
      expect(Open3).not_to(have_received(:capture2).with('lsof', any_args))
    end

    context 'with a Linux /proc/pid/fd directory' do
      before do
        allow(File).to(receive(:directory?).with('/proc/123/fd').and_return(true))
        allow(File).to(receive(:exist?).with(%r{\A/proc/123/net/tcp6?\z}).and_return(true))
        allow(File).to(
          receive(:read).with('/proc/123/net/tcp').and_return(
            "  sl local rem st ... inode\n  " \
              "0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n  " \
              "1: 0100007F:1F91 00000000:0000 0A 00:00 00 00 0 0 999 1\n"
          )
        )
        allow(File).to(
          receive(:read).with('/proc/123/net/tcp6').and_return(
            "  sl local rem st ... inode\n  0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 777 1\n"
          )
        )
        allow(Dir).to(receive(:glob).with('/proc/123/fd/*').and_return(%w[/proc/123/fd/1 /proc/123/fd/2]))
        allow(File).to(receive(:readlink).with('/proc/123/fd/1').and_return('socket:[555]'))
        allow(File).to(receive(:readlink).with('/proc/123/fd/2').and_return('socket:[777]'))
      end

      it 'counts the socket fds whose inode is ESTABLISHED in net/tcp or net/tcp6' do
        expect(counter.count_established_connections(123)).to(eq(2))
      end

      it 'does not count a listening socket' do
        allow(File).to(receive(:readlink).with('/proc/123/fd/2').and_return('socket:[999]'))
        expect(counter.count_established_connections(123)).to(eq(1))
      end

      it 'reads only the net files that exist (tcp6 absent) rather than failing' do
        allow(File).to(receive(:exist?).with('/proc/123/net/tcp6').and_return(false))
        expect(counter.count_established_connections(123)).to(eq(1))
      end

      it 'finds no connections when neither net file exists' do
        allow(File).to(receive(:exist?).with(%r{\A/proc/123/net/tcp6?\z}).and_return(false))
        expect(counter.count_established_connections(123)).to(eq(0))
      end
    end

    it 'counts only (ESTABLISHED) lines via lsof when /proc/pid/fd is absent' do
      allow(File).to(receive(:directory?).with('/proc/123/fd').and_return(false))
      lsof = "COMMAND PID\nruby 123 TCP *:8080 (ESTABLISHED)\nruby 123 TCP *:9 (LISTEN)\n" \
        "ruby 123 TCP *:7 (ESTABLISHED)\n"
      allow(Open3).to(receive(:capture2).with('lsof', '-p', '123', '-n', '-P').and_return([lsof, nil]))
      expect(counter.count_established_connections(123)).to(eq(2))
    end

    it 'rescues any error and returns zero' do
      allow(File).to(receive(:directory?).with('/proc/123/fd').and_raise(StandardError))
      expect(counter.count_established_connections(123)).to(eq(0))
    end
  end

  describe '#established_inodes (private)' do
    before do
      allow(File).to(receive(:exist?).with('/proc/9/net/tcp').and_return(true))
      allow(File).to(receive(:exist?).with('/proc/9/net/tcp6').and_return(false))
      allow(File).to(
        receive(:read).with('/proc/9/net/tcp').and_return(
          "  sl local rem st ... inode\n  " \
            "0: 0100007F:1F90 0100007F:C000 01 00:00 00 00 0 0 555 1\n  " \
            "1: 0100007F:1F91 00000000:0000 0A 00:00 00 00 0 0 999 1\n"
        )
      )
    end

    it 'collects state-01 inodes from tcp, skipping non-ESTABLISHED rows and a missing proto file' do
      expect(counter.__send__(:established_inodes, 9)).to(eq(['555']))
    end

    it 'merges inodes from both proto files, in tcp-then-tcp6 order, when both are present' do
      allow(File).to(receive(:exist?).with('/proc/9/net/tcp6').and_return(true))
      allow(File).to(
        receive(:read).with('/proc/9/net/tcp6').and_return(
          "  sl local rem st ... inode\n  0: ::1:1F90 ::1:C000 01 00:00 00 00 0 0 777 1\n"
        )
      )
      expect(counter.__send__(:established_inodes, 9)).to(eq(%w[555 777]))
    end
  end

  describe '#socket_inode (private)' do
    it 'extracts the inode from a bare socket symlink target' do
      allow(File).to(receive(:readlink).with('/proc/9/fd/3').and_return('socket:[12345]'))
      expect(counter.__send__(:socket_inode, '/proc/9/fd/3')).to(eq('12345'))
    end

    it 'returns nil for a non-socket descriptor target' do
      allow(File).to(receive(:readlink).with('/proc/9/fd/4').and_return(File::NULL))
      expect(counter.__send__(:socket_inode, '/proc/9/fd/4').nil?).to(be(true))
    end

    it 'anchors the match, rejecting a socket:[n] fragment embedded in a longer target' do
      allow(File).to(receive(:readlink).with('/proc/9/fd/5').and_return('anon_inode:socket:[7]x'))
      expect(counter.__send__(:socket_inode, '/proc/9/fd/5').nil?).to(be(true))
    end
  end

  describe '#fd_socket_inodes (private)' do
    it 'maps socket fds to inodes, dropping non-sockets and descriptors that vanish mid-walk' do
      allow(Dir).to(receive(:glob).with('/proc/9/fd/*').and_return(%w[/proc/9/fd/1 /proc/9/fd/2 /proc/9/fd/3]))
      allow(File).to(receive(:readlink).with('/proc/9/fd/1').and_return('socket:[100]'))
      allow(File).to(receive(:readlink).with('/proc/9/fd/2').and_return(File::NULL))
      allow(File).to(receive(:readlink).with('/proc/9/fd/3').and_raise(StandardError))
      expect(counter.__send__(:fd_socket_inodes, 9)).to(eq(['100']))
    end
  end

  describe '#count_linux_connections (private)' do
    it 'counts only the fd inodes that appear in the established set' do
      allow(counter).to(receive(:established_inodes).with(9).and_return(%w[100 300]))
      allow(counter).to(receive(:fd_socket_inodes).with(9).and_return(%w[100 200 300]))
      expect(counter.__send__(:count_linux_connections, 9)).to(eq(2))
    end
  end
end

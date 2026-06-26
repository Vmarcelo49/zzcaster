// Package main — TCP listener for the relay server.
//
// Each TCP connection is handled in its own goroutine. The first message
// from the peer is classified as HostRegister or ClientJoin; subsequent
// reads block until the server has something to send (MatchInfo, TunInfo,
// or Error).
//
// Connections are kept open for the lifetime of the room. The relay uses
// TCP disconnect as a signal that a peer has gone away — if the host's
// TCP closes, the room is deleted.
package main

import (
        "bufio"
        "context"
        "errors"
        "fmt"
        "io"
        "log"
        "net"
        "time"
)

// TCPListenerConfig configures the TCP listener.
type TCPListenerConfig struct {
        Addr            string        // ":3939"
        ReadTimeout     time.Duration // timeout for the FIRST read (host/join). 0 = no timeout
        RoomTTL         time.Duration // how long a room lives before expiring
        CleanupInterval time.Duration // how often to run RoomManager.Cleanup
}

func DefaultTCPConfig() TCPListenerConfig {
        return TCPListenerConfig{
                Addr:            ":3939",
                ReadTimeout:     30 * time.Second,
                RoomTTL:         60 * time.Second,
                CleanupInterval: 10 * time.Second,
        }
}

// StartTCPListener starts the TCP listener. Blocks until the context is
// cancelled. Returns nil on graceful shutdown.
func StartTCPListener(ctx context.Context, cfg TCPListenerConfig, rm *RoomManager, logger *log.Logger) error {
        ln, err := net.Listen("tcp", cfg.Addr)
        if err != nil {
                return fmt.Errorf("tcp listen on %s: %w", cfg.Addr, err)
        }
        defer ln.Close()
        logger.Printf("TCP listening on %s", cfg.Addr)

        // Cleanup goroutine
        go startCleanupLoop(ctx, rm, cfg.CleanupInterval, logger)

        // Close listener on context cancel
        go func() {
                <-ctx.Done()
                ln.Close()
        }()

        for {
                conn, err := ln.Accept()
                if err != nil {
                        if errors.Is(err, net.ErrClosed) {
                                return nil
                        }
                        logger.Printf("tcp accept error: %v", err)
                        continue
                }
                go handleTCPConn(ctx, conn, cfg, rm, logger)
        }
}

// handleTCPConn runs in its own goroutine per connection.
func handleTCPConn(ctx context.Context, conn net.Conn, cfg TCPListenerConfig, rm *RoomManager, logger *log.Logger) {
        defer conn.Close()

        remoteAddr := conn.RemoteAddr().(*net.TCPAddr)
        peerTCPAddr := fmt.Sprintf("%s:%d", remoteAddr.IP.String(), remoteAddr.Port)
        logger.Printf("TCP connect from %s", peerTCPAddr)

        // First read — HostRegister or ClientJoin
        if cfg.ReadTimeout > 0 {
                conn.SetReadDeadline(time.Now().Add(cfg.ReadTimeout))
        }

        br := bufio.NewReader(conn)
        firstMsg, err := readInitialMessage(br)
        if err != nil {
                logger.Printf("read initial from %s: %v", peerTCPAddr, err)
                return
        }

        // Clear the read deadline — from here on, the conn blocks waiting
        // for the server to push MatchInfo / TunInfo / Error.
        conn.SetReadDeadline(time.Time{})

        incoming, err := ClassifyIncomingTCP(firstMsg)
        if err != nil {
                logger.Printf("classify from %s: %v", peerTCPAddr, err)
                conn.Write(EncodeError(ErrProtocolError.Code, err.Error()))
                return
        }

        peerConn := &PeerConn{
                TCPAddr: peerTCPAddr,
                Conn:    conn,
        }

        switch incoming.Kind {
        case KindHostRegister:
                handleHostRegister(ctx, conn, peerConn, incoming.HostRegister, cfg, rm, logger)
        case KindClientJoin:
                peerConn.IsClient = true
                handleClientJoin(ctx, conn, peerConn, incoming.ClientJoin, cfg, rm, logger)
        default:
                logger.Printf("unknown message kind from %s", peerTCPAddr)
                conn.Write(EncodeError(ErrProtocolError.Code, "unknown message kind"))
        }
}

// readInitialMessage reads the first packet from a fresh TCP connection.
// We don't use length-prefix on the initial message — we read up to a
// small max and rely on the message's own structure to delimit it.
//
// HostRegister: 4 + code_len (4-8 bytes)
// ClientJoin:   2 + code_len (6 bytes — code_len is always 4)
//
// We peek the first 4 bytes to decide which kind, then read exactly
// the right number of bytes.
func readInitialMessage(br *bufio.Reader) ([]byte, error) {
        peek, err := br.Peek(4)
        if err != nil {
                return nil, err
        }

        // If the 4th byte (data[3]) is a plausible code_len (0..4), treat
        // as HostRegister and read 4 + code_len bytes.
        if peek[3] <= 4 {
                totalLen := 4 + int(peek[3])
                buf := make([]byte, totalLen)
                _, err = io.ReadFull(br, buf)
                return buf, err
        }

        // Otherwise, ClientJoin — read 2 bytes for the header, then
        // code_len bytes for the code.
        header, err := br.Peek(2)
        if err != nil {
                return nil, err
        }
        totalLen := 2 + int(header[1])
        buf := make([]byte, totalLen)
        _, err = io.ReadFull(br, buf)
        return buf, err
}

// handleHostRegister processes a HostRegister: create a room, reply
// with Hosted, then keep the TCP open until a client joins (MatchInfo)
// and the UDP exchange completes (TunInfo).
func handleHostRegister(
        ctx context.Context,
        conn net.Conn,
        peerConn *PeerConn,
        hr *HostRegister,
        cfg TCPListenerConfig,
        rm *RoomManager,
        logger *log.Logger,
) {
        assignedCode, _, err := rm.RegisterHost(hr.Code, peerConn, cfg.RoomTTL)
        if err != nil {
                logger.Printf("register host from %s: %v", peerConn.TCPAddr, err)
                conn.Write(EncodeError(ErrRoomTaken.Code, "room code taken"))
                return
        }

        // Reply with Hosted so the host learns its assigned code.
        if _, err := conn.Write(EncodeHosted(assignedCode)); err != nil {
                logger.Printf("write Hosted to %s: %v", peerConn.TCPAddr, err)
                rm.Delete(assignedCode)
                return
        }

        logger.Printf("host registered: code=%s addr=%s port=%d", assignedCode, peerConn.TCPAddr, hr.Port)

        // Block until the room is matched (state transitions to RoomMatched)
        // or the connection closes / context cancels / TTL expires.
        ticker := time.NewTicker(100 * time.Millisecond)
        defer ticker.Stop()

        for {
                select {
                case <-ctx.Done():
                        rm.Delete(assignedCode)
                        return
                case <-ticker.C:
                        r := rm.LookupByHostCode(assignedCode)
                        if r == nil {
                                // Room was deleted (TTL expired or client error)
                                logger.Printf("host: room %s gone", assignedCode)
                                return
                        }
                        if r.State == RoomMatched {
                                // Send MatchInfo
                                if _, err := conn.Write(EncodeMatchInfo(r.MatchId)); err != nil {
                                        logger.Printf("write MatchInfo to host %s: %v", peerConn.TCPAddr, err)
                                        rm.Delete(assignedCode)
                                        return
                                }
                                logger.Printf("host: sent MatchInfo for room %s matchId=%d", assignedCode, r.MatchId)
                                // Now wait for the UDP handler to send TunInfo directly
                                // to this conn. We just block here until the conn closes.
                                waitForConnClose(ctx, conn, logger, peerConn.TCPAddr)
                                return
                        }
                }
        }
}

// handleClientJoin processes a ClientJoin: look up the room, attach
// self as client, send MatchInfo, then wait for the relay's UDP handler
// to send TunInfo.
func handleClientJoin(
        ctx context.Context,
        conn net.Conn,
        peerConn *PeerConn,
        cj *ClientJoin,
        cfg TCPListenerConfig,
        rm *RoomManager,
        logger *log.Logger,
) {
        _, matchId, err := rm.JoinClient(cj.Code, peerConn, cfg.RoomTTL)
        if err != nil {
                logger.Printf("join client from %s code=%s: %v", peerConn.TCPAddr, cj.Code, err)
                if re, ok := err.(*RoomError); ok {
                        conn.Write(EncodeError(re.Code, re.Msg))
                } else {
                        conn.Write(EncodeError(ErrProtocolError.Code, err.Error()))
                }
                return
        }

        // Send MatchInfo to client.
        if _, err := conn.Write(EncodeMatchInfo(matchId)); err != nil {
                logger.Printf("write MatchInfo to client %s: %v", peerConn.TCPAddr, err)
                rm.Delete(cj.Code)
                return
        }

        logger.Printf("client joined: code=%s matchId=%d addr=%s", cj.Code, matchId, peerConn.TCPAddr)

        // Wait for the UDP handler to send TunInfo directly to this conn.
        // Block until the conn closes.
        waitForConnClose(ctx, conn, logger, peerConn.TCPAddr)
}

// waitForConnClose blocks until the TCP connection is closed (peer
// disconnects) or the context is cancelled. Used after MatchInfo is
// sent — the relay's TCP job is done, but we keep the socket open so
// the UDP handler can still write TunInfo to it.
//
// We do a low-rate background read to detect disconnect. If the read
// returns any data, that's unexpected (the protocol has no client-to-
// server messages after the initial one) — we log and ignore.
func waitForConnClose(ctx context.Context, conn net.Conn, logger *log.Logger, label string) {
        buf := make([]byte, 64)
        done := make(chan struct{})
        go func() {
                for {
                        n, err := conn.Read(buf)
                        if err != nil {
                                close(done)
                                return
                        }
                        if n > 0 {
                                logger.Printf("unexpected %d bytes from %s after MatchInfo", n, label)
                        }
                }
        }()
        select {
        case <-done:
                logger.Printf("conn closed by %s", label)
        case <-ctx.Done():
        }
}

// startCleanupLoop periodically calls RoomManager.Cleanup.
func startCleanupLoop(ctx context.Context, rm *RoomManager, interval time.Duration, logger *log.Logger) {
        if interval <= 0 {
                interval = 10 * time.Second
        }
        ticker := time.NewTicker(interval)
        defer ticker.Stop()
        for {
                select {
                case <-ctx.Done():
                        return
                case <-ticker.C:
                        removed := rm.Cleanup()
                        if removed > 0 {
                                logger.Printf("cleanup: removed %d expired rooms", removed)
                        }
                }
        }
}

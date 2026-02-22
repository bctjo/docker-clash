import * as React from 'react';
import { ArrowDown, Pause, Play, Trash2 } from 'react-feather';
import { useTranslation } from 'react-i18next';

import { fetchLogs, reconnect as reconnectLogs, stop as stopLogs } from '~/api/logs';
import ContentHeader from '~/components/ContentHeader';
import LogSearch from '~/components/LogSearch';
import { connect, useStoreActions } from '~/components/StateProvider';
import SvgYacd from '~/components/SvgYacd';
import useRemainingViewPortHeight from '~/hooks/useRemainingViewPortHeight';
import { getClashAPIConfig, getLogStreamingPaused } from '~/store/app';
import { getLogLevel } from '~/store/configs';
import { appendLog, clearLogs, getLogsForDisplay } from '~/store/logs';
import { Log, State } from '~/store/types';

import s from './Logs.module.scss';
import { Fab, position as fabPosition } from './shared/Fab';

const { useCallback, useEffect, useRef, useState } = React;

const logTypes = {
  debug: 'debug',
  info: 'info',
  warning: 'warn',
  error: 'error',
};

type LogLineProps = Partial<Log>;

function LogLine({ time, payload, type }: LogLineProps) {
  return (
    <div className={s.logLine}>
      <div className={s.logMeta}>
        <span className={s.logTime}>{time}</span>
        <span className={s.logType} data-type={type}>
          {logTypes[type]}
        </span>
      </div>
      <div className={s.logText}>{payload}</div>
    </div>
  );
}

function Logs({ dispatch, logLevel, apiConfig, logs, logStreamingPaused }) {
  const actions = useStoreActions();
  const toggleIsRefreshPaused = useCallback(() => {
    logStreamingPaused ? reconnectLogs({ ...apiConfig, logLevel }) : stopLogs();
    // being lazy here
    // ideally we should check the result of previous operation before updating this
    actions.app.updateAppConfig('logStreamingPaused', !logStreamingPaused);
  }, [apiConfig, logLevel, logStreamingPaused, actions.app]);
  const appendLogInternal = useCallback((log) => dispatch(appendLog(log)), [dispatch]);
  useEffect(() => {
    fetchLogs({ ...apiConfig, logLevel }, appendLogInternal);
  }, [apiConfig, logLevel, appendLogInternal]);
  const [refLogsContainer, containerHeight] = useRemainingViewPortHeight();
  const { t } = useTranslation();

  const scrollRef = useRef<HTMLDivElement>(null);
  const [isAtBottom, setIsAtBottom] = useState(true);

  const scrollToBottom = useCallback(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, []);

  useEffect(() => {
    if (isAtBottom) {
      scrollToBottom();
    }
  }, [logs, isAtBottom, scrollToBottom]);

  const onScroll = useCallback((e: React.UIEvent<HTMLDivElement>) => {
    const { scrollTop, scrollHeight, clientHeight } = e.currentTarget;
    const atBottom = scrollHeight - scrollTop - clientHeight < 50;
    setIsAtBottom(atBottom);
  }, []);

  return (
    <div>
      <ContentHeader>
        <div style={{ flex: 1 }} />
        <div className={s.headerControls}>
          <LogSearch className={s.searchWrapper} />
          <button className={s.clearBtn} onClick={() => dispatch(clearLogs())} title={t('Clear')}>
            <Trash2 size={18} />
          </button>
        </div>
      </ContentHeader>
      <div ref={refLogsContainer} style={{ position: 'relative' }}>
        {logs.length === 0 ? (
          <div className={s.logPlaceholder} style={{ height: containerHeight * 0.9 }}>
            <div className={s.logPlaceholderIcon}>
              <SvgYacd width={200} height={200} />
            </div>
            <div>{t('no_logs')}</div>
          </div>
        ) : (
          <>
            <div
              className={s.logsWrapper}
              style={{ height: containerHeight * 0.8 }}
              ref={scrollRef}
              onScroll={onScroll}
            >
              {logs.map((log, index) => (
                <LogLine {...log} key={log.id || index} />
              ))}
            </div>

            {!isAtBottom && (
              <button className={s.scrollToBottomBtn} onClick={scrollToBottom}>
                <ArrowDown size={16} />
              </button>
            )}

            <Fab
              icon={logStreamingPaused ? <Play size={16} /> : <Pause size={16} />}
              mainButtonStyles={logStreamingPaused ? { background: '#e74c3c' } : {}}
              style={fabPosition}
              text={logStreamingPaused ? t('Resume Refresh') : t('Pause Refresh')}
              onClick={toggleIsRefreshPaused}
            ></Fab>
          </>
        )}
      </div>
    </div>
  );
}

const mapState = (s: State) => ({
  logs: getLogsForDisplay(s),
  logLevel: getLogLevel(s),
  apiConfig: getClashAPIConfig(s),
  logStreamingPaused: getLogStreamingPaused(s),
});

export default connect(mapState)(Logs);

import { Tooltip } from '@reach/tooltip';
import cx from 'clsx';
import * as React from 'react';
import { useTranslation } from 'react-i18next';

import Button from '~/components/Button';
import ContentHeader from '~/components/ContentHeader';
import { ClosePrevConns } from '~/components/proxies/ClosePrevConns';
import { ProxyGroup } from '~/components/proxies/ProxyGroup';
import { ProxyPageFab } from '~/components/proxies/ProxyPageFab';
import { ProxyProvider } from '~/components/proxies/ProxyProvider';
import Settings from '~/components/proxies/Settings';
import BaseModal from '~/components/shared/BaseModal';
import { TextFilter } from '~/components/shared/TextFitler';
import { connect, useStoreActions } from '~/components/StateProvider';
import Equalizer from '~/components/svg/Equalizer';
import { getClashAPIConfig, getProxiesLayout } from '~/store/app';
import {
  fetchProxies,
  getDelay,
  getProxyGroupNames,
  getProxyProviders,
  getShowModalClosePrevConns,
  proxyFilterText,
} from '~/store/proxies';
import type { State } from '~/store/types';

import s0 from './Proxies.module.scss';

const { useState, useEffect, useCallback, useRef, useMemo } = React;

function Proxies({
  dispatch,
  groupNames,
  delay,
  proxyProviders,
  apiConfig,
  showModalClosePrevConns,
  proxiesLayout,
}) {
  const refFetchedTimestamp = useRef<{ startAt?: number; completeAt?: number }>({});

  const formatQty = (qty: number) => (qty < 100 ? '' + qty : '99+');

  const fetchProxiesHooked = useCallback(() => {
    refFetchedTimestamp.current.startAt = Date.now();
    dispatch(fetchProxies(apiConfig)).then(() => {
      refFetchedTimestamp.current.completeAt = Date.now();
    });
  }, [apiConfig, dispatch]);
  useEffect(() => {
    // fetch it now
    fetchProxiesHooked();

    // arm a window on focus listener to refresh it
    const fn = () => {
      if (
        refFetchedTimestamp.current.startAt &&
        Date.now() - refFetchedTimestamp.current.startAt > 3e4 // 30s
      ) {
        fetchProxiesHooked();
      }
    };
    window.addEventListener('focus', fn, false);
    return () => window.removeEventListener('focus', fn, false);
  }, [fetchProxiesHooked]);

  const [isSettingsModalOpen, setIsSettingsModalOpen] = useState(false);
  const closeSettingsModal = useCallback(() => {
    setIsSettingsModalOpen(false);
  }, []);

  const [activeTab, setActiveTab] = useState('proxies');

  const handleTabKeyDown = useCallback(
    (tab: string) => (e: React.KeyboardEvent) => {
      if (e.key === 'Enter' || e.key === ' ') {
        setActiveTab(tab);
      }
    },
    []
  );

  const {
    proxies: { closeModalClosePrevConns, closePrevConnsAndTheModal },
  } = useStoreActions();

  const { t } = useTranslation();

  const proxyGroups = useMemo(() => {
    const formatted = groupNames.map((name, i) => ({ name, i }));
    if (proxiesLayout !== 'double') return [formatted];
    const left = [];
    const right = [];
    formatted.forEach((item, i) => {
      if (i % 2 === 0) left.push(item);
      else right.push(item);
    });
    return [left, right];
  }, [groupNames, proxiesLayout]);

  const providers = useMemo(() => {
    const formatted = proxyProviders.map((item, i) => ({ item, i }));
    if (proxiesLayout !== 'double') return [formatted];
    const left = [];
    const right = [];
    formatted.forEach((item, i) => {
      if (i % 2 === 0) left.push(item);
      else right.push(item);
    });
    return [left, right];
  }, [proxyProviders, proxiesLayout]);

  return (
    <>
      <BaseModal isOpen={isSettingsModalOpen} onRequestClose={closeSettingsModal}>
        <Settings />
      </BaseModal>
      <div className={s0.topBar}>
        <ContentHeader>
          <div className={s0.tabsContainer}>
            <div
              className={cx(s0.tab, { [s0.active]: activeTab === 'proxies' })}
              onClick={() => setActiveTab('proxies')}
              onKeyDown={handleTabKeyDown('proxies')}
              role="button"
              tabIndex={0}
            >
              {t('Proxies')}
              <span className={s0.tabCount}>{formatQty(groupNames.length)}</span>
            </div>
            {proxyProviders.length > 0 && (
              <div
                className={cx(s0.tab, { [s0.active]: activeTab === 'providers' })}
                onClick={() => setActiveTab('providers')}
                onKeyDown={handleTabKeyDown('providers')}
                role="button"
                tabIndex={0}
              >
                {t('proxy_provider')}
                <span className={s0.tabCount}>{formatQty(proxyProviders.length)}</span>
              </div>
            )}
          </div>
          <div style={{ flex: 1 }} />
          <div className={s0.topBarRight}>
            <div className={s0.textFilterContainer}>
              <TextFilter textAtom={proxyFilterText} placeholder={t('Search')} />
            </div>
            <Tooltip label={t('settings')}>
              <Button kind="minimal" onClick={() => setIsSettingsModalOpen(true)}>
                <Equalizer size={16} />
              </Button>
            </Tooltip>
          </div>
        </ContentHeader>
      </div>
      {activeTab === 'proxies' ? (
        <div className={cx(s0.groupsContainer, { [s0.doubleColumn]: proxiesLayout === 'double' })}>
          {proxyGroups.map((column, i) => (
            <div key={i} className={s0.column}>
              {column.map(({ name, i: originalIndex }) => (
                <div className={s0.group} key={name} style={{ order: originalIndex }}>
                  <ProxyGroup name={name} delay={delay} apiConfig={apiConfig} dispatch={dispatch} />
                </div>
              ))}
            </div>
          ))}
        </div>
      ) : (
        <div className={cx(s0.groupsContainer, { [s0.doubleColumn]: proxiesLayout === 'double' })}>
          {providers.map((column, i) => (
            <div key={i} className={s0.column}>
              {column.map(({ item, i: originalIndex }) => (
                <div className={s0.group} key={item.name} style={{ order: originalIndex }}>
                  <ProxyProvider
                    name={item.name}
                    proxies={item.proxies}
                    type={item.type}
                    vehicleType={item.vehicleType}
                    updatedAt={item.updatedAt}
                    subscriptionInfo={item.subscriptionInfo}
                  />
                </div>
              ))}
            </div>
          ))}
        </div>
      )}
      <div style={{ height: 60 }} />
      <ProxyPageFab dispatch={dispatch} apiConfig={apiConfig} proxyProviders={proxyProviders} />
      <BaseModal isOpen={showModalClosePrevConns} onRequestClose={closeModalClosePrevConns}>
        <ClosePrevConns
          onClickPrimaryButton={() => closePrevConnsAndTheModal(apiConfig)}
          onClickSecondaryButton={closeModalClosePrevConns}
        />
      </BaseModal>
    </>
  );
}

const mapState = (s: State) => ({
  apiConfig: getClashAPIConfig(s),
  groupNames: getProxyGroupNames(s),
  proxyProviders: getProxyProviders(s),
  delay: getDelay(s),
  showModalClosePrevConns: getShowModalClosePrevConns(s),
  proxiesLayout: getProxiesLayout(s),
});

export default connect(mapState)(Proxies);
